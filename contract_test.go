package logbook_test

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/bits"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const (
	contractDir        = "testdata/contract"
	contractEpoch      = "2026-01-05T09:00:00Z"
	defaultLeaseWindow = 60 * time.Second
	defaultPoWBits     = 20
	dailyVisitorLimit  = 5
)

type contractExample struct {
	About   string          `json:"about"`
	Given   *contractGiven  `json:"given,omitempty"`
	Request contractRequest `json:"request"`
	Expect  contractExpect  `json:"expect"`
}

type contractGiven struct {
	Items     []seedItem        `json:"items,omitempty"`
	Calls     []contractRequest `json:"calls,omitempty"`
	Wait      string            `json:"wait,omitempty"`
	Condition string            `json:"condition,omitempty"`
}

type seedItem struct {
	ID    string `json:"id"`
	State string `json:"state"`
	Lane  string `json:"lane"`
	Next  string `json:"next"`
}

type contractRequest struct {
	As          string          `json:"as,omitempty"`
	Method      string          `json:"method"`
	Path        string          `json:"path"`
	ContentType *string         `json:"content_type,omitempty"`
	Body        json.RawMessage `json:"body,omitempty"`
	Raw         *string         `json:"raw,omitempty"`
}

type contractExpect struct {
	Status int             `json:"status"`
	Body   json.RawMessage `json:"body,omitempty"`
	Stream *string         `json:"stream,omitempty"`
}

type problem struct {
	Status int
	Code   string
	Cause  string
	Reason string
}

func (p *problem) Error() string {
	return fmt.Sprintf("%d %s %s: %s", p.Status, p.Code, p.Cause, p.Reason)
}

var (
	probNotJSON         = &problem{http.StatusBadRequest, "E_PARSE", "not_json", "the request is not one json value"}
	probUnknownField    = &problem{http.StatusBadRequest, "E_PARSE", "unknown_field", "the request has a field this call does not define"}
	probMissingField    = &problem{http.StatusBadRequest, "E_PARSE", "missing_field", "a required field is missing"}
	probBadField        = &problem{http.StatusBadRequest, "E_PARSE", "bad_field", "a field does not have the form this call requires"}
	probUseNeedsSubtool = &problem{http.StatusBadRequest, "E_PARSE", "bad_field", "report a missing rule with the needs_subtool call"}
	probBadProof        = &problem{http.StatusBadRequest, "E_PARSE", "bad_field", "the proof of work is not valid"}
	probUnknownTarget   = &problem{http.StatusBadRequest, "E_PARSE", "bad_field", "the target is not in the ownership map"}
	probNothingLeft     = &problem{http.StatusBadRequest, "E_PARSE", "bad_field", "nothing is left of the text once markup is removed"}
	probLogbookRefused  = &problem{http.StatusBadRequest, "E_PARSE", "bad_field", "the record store refused a field"}

	probNoCredential = &problem{http.StatusUnauthorized, "E_PARSE", "no_credential", "no valid credential was presented"}
	probNotYourCall  = &problem{http.StatusForbidden, "E_PARSE", "not_your_call", "this caller may not make this call"}
	probNoSuchCall   = &problem{http.StatusNotFound, "E_PARSE", "no_such_call", "no such call"}
	probWrongMethod  = &problem{http.StatusMethodNotAllowed, "E_PARSE", "wrong_method", "this call does not accept that method"}
	probTooLarge     = &problem{http.StatusRequestEntityTooLarge, "E_PARSE", "too_large", "the request is too large"}
	probWrongType    = &problem{http.StatusUnsupportedMediaType, "E_PARSE", "wrong_type", "the content type must be application/json"}

	probLeaseNotHeld   = &problem{http.StatusConflict, "E_PARSE", "lease_not_held", "the lease is not held"}
	probMoveNotAllowed = &problem{http.StatusConflict, "E_PARSE", "move_not_allowed", "that move is not allowed"}
	probDuplicate      = &problem{http.StatusConflict, "E_PARSE", "duplicate", "the same component is reported twice in one batch"}

	probUnknownContract   = &problem{http.StatusUnprocessableEntity, "E_NEEDS_SUBTOOL", "unknown_contract", "this contract version is not known"}
	probUnknownHealth     = &problem{http.StatusUnprocessableEntity, "E_NEEDS_SUBTOOL", "unknown_value", "this health state is not known"}
	probUnknownSource     = &problem{http.StatusUnprocessableEntity, "E_NEEDS_SUBTOOL", "unknown_value", "this source is not known"}
	probLogbookUnfamiliar = &problem{http.StatusUnprocessableEntity, "E_NEEDS_SUBTOOL", "unknown_value", "the record store has no rule for a value"}

	probRateLimited = &problem{http.StatusTooManyRequests, "E_TIMEOUT", "rate_limited", "too many submissions from this visitor today; try again tomorrow"}

	probStoreSlow    = &problem{http.StatusServiceUnavailable, "E_TIMEOUT", "store_slow", "the record store took too long"}
	probBusy         = &problem{http.StatusServiceUnavailable, "E_TIMEOUT", "busy", "too busy; try again"}
	probIdentitySlow = &problem{http.StatusServiceUnavailable, "E_TIMEOUT", "busy", "the identity check took too long; try again"}

	probBadRecord  = &problem{http.StatusInternalServerError, "E_PARSE", "bad_record", "a stored record was not consistent and has been set aside"}
	probUnexpected = &problem{http.StatusInternalServerError, "E_PARSE", "unexpected", "an unexpected condition; the request was refused"}
)

func allContractProblems() []*problem {
	return []*problem{
		probNotJSON, probUnknownField, probMissingField, probBadField, probUseNeedsSubtool,
		probBadProof, probUnknownTarget, probNothingLeft, probLogbookRefused,
		probNoCredential, probNotYourCall, probNoSuchCall, probWrongMethod, probTooLarge, probWrongType,
		probLeaseNotHeld, probMoveNotAllowed, probDuplicate,
		probUnknownContract, probUnknownHealth, probUnknownSource, probLogbookUnfamiliar,
		probRateLimited, probStoreSlow, probBusy, probIdentitySlow, probBadRecord, probUnexpected,
	}
}

func allContractPaths() []string {
	return []string{
		"/healthz",
		"/v1/complete",
		"/v1/edits",
		"/v1/fail",
		"/v1/feed",
		"/v1/health",
		"/v1/heartbeat",
		"/v1/items",
		"/v1/lease",
		"/v1/needs_subtool",
		"/v1/release",
	}
}

type routeRule struct {
	Worker    string
	Kind      string
	From      string
	To        string
	Next      string
	Lane      string
	AfterDays int
}

var contractRoutes = []routeRule{
	{Worker: "trawl", Kind: "item", From: "discovered", To: "recorded", Next: "sextant", Lane: "normal"},
	{Worker: "trawl", Kind: "item", From: "discovered", To: "rejected"},
	{Worker: "sextant", Kind: "item", From: "recorded", To: "observed", Next: "assay", Lane: "normal"},
	{Worker: "assay", Kind: "item", From: "observed", To: "scored", Next: "countersign", Lane: "normal"},
	{Worker: "assay", Kind: "item", From: "observed", To: "screened_out", Next: "countersign", Lane: "normal"},
	{Worker: "countersign", Kind: "item", From: "scored", To: "approved", Next: "waybill", Lane: "normal"},
	{Worker: "countersign", Kind: "item", From: "scored", To: "parked"},
	{Worker: "countersign", Kind: "item", From: "scored", To: "linked", Next: "chartroom", Lane: "normal"},
	{Worker: "countersign", Kind: "item", From: "scored", To: "merged", Next: "chartroom", Lane: "normal"},
	{Worker: "countersign", Kind: "item", From: "scored", To: "rejected"},
	{Worker: "countersign", Kind: "item", From: "screened_out", To: "observed", Next: "assay", Lane: "normal"},
	{Worker: "waybill", Kind: "item", From: "approved", To: "approved", Next: "moldloft", Lane: "normal"},
	{Worker: "moldloft", Kind: "item", From: "approved", To: "building", Next: "shakedown", Lane: "normal"},
	{Worker: "shakedown", Kind: "item", From: "building", To: "building", Next: "chartroom", Lane: "normal"},
	{Worker: "shakedown", Kind: "item", From: "building", To: "parked"},
	{Worker: "chartroom", Kind: "item", From: "building", To: "live", Next: "tidegauge", Lane: "backfill", AfterDays: 7},
	{Worker: "chartroom", Kind: "item", From: "linked", To: "linked"},
	{Worker: "chartroom", Kind: "item", From: "merged", To: "merged"},
	{Worker: "chartroom", Kind: "item", From: "retired", To: "retired"},
	{Worker: "tidegauge", Kind: "item", From: "live", To: "live", Next: "tidegauge", Lane: "backfill", AfterDays: 7},
	{Worker: "tidegauge", Kind: "item", From: "live", To: "retired", Next: "chartroom", Lane: "urgent"},
	{Worker: "tidegauge", Kind: "item", From: "live", To: "building", Next: "waybill", Lane: "urgent"},
	{Worker: "waybill", Kind: "item", From: "building", To: "building", Next: "moldloft", Lane: "urgent"},
	{Worker: "moldloft", Kind: "item", From: "building", To: "building", Next: "shakedown", Lane: "urgent"},

	{Worker: "countersign", Kind: "proposal", From: "pending_approval", To: "approved", Next: "bellbuoy", Lane: "urgent"},
	{Worker: "countersign", Kind: "proposal", From: "pending_approval", To: "declined"},
	{Worker: "bellbuoy", Kind: "proposal", From: "approved", To: "building"},
}

var workerCallers = map[string]bool{
	"trawl":       true,
	"sextant":     true,
	"assay":       true,
	"countersign": true,
	"waybill":     true,
	"moldloft":    true,
	"shakedown":   true,
	"chartroom":   true,
	"tidegauge":   true,
	"bellbuoy":    true,
}

var knownComponents = map[string]string{
	"logbook":     "logbook",
	"muster":      "muster",
	"assay":       "assay",
	"countersign": "countersign",
	"trawl":       "trawl",
	"sextant":     "sextant",
	"chartroom":   "chartroom",
	"waybill":     "waybill",
	"moldloft":    "moldloft",
	"shakedown":   "shakedown",
	"tidegauge":   "tidegauge",
	"bellbuoy":    "bellbuoy",
	"keelworks":   "keelworks",
	"lazarette":   "lazarette",
	"shipkeeper":  "shipkeeper",
	"conn":        "clearedstack.com",
}

var sourceLanes = map[string]string{
	"sam-gov":       "normal",
	"github-issues": "normal",
	"web-sweep":     "backfill",
	"site-form":     "urgent",
}

var pausableItemStates = map[string]bool{
	"recorded": true,
	"observed": true,
	"approved": true,
}

type ownershipEntry struct {
	Repository string
	File       string
	Kind       string
}

var sampleOwnershipMap = map[string]ownershipEntry{
	"catalog.sample-calculator.description": {
		Repository: "clearedstack.com",
		File:       "src/data/sample-catalog.json",
		Kind:       "DATA",
	},
}

type pgCluster struct {
	env  []string
	sock string
	seq  atomic.Int64
}

func startPGCluster(t *testing.T) *pgCluster {
	t.Helper()
	baseEnv := postgresEnv(t)

	root := t.TempDir()
	dataDir := filepath.Join(root, "data")
	sockDir := filepath.Join(root, "sock")
	logFile := filepath.Join(root, "postgres.log")
	if err := os.MkdirAll(sockDir, 0o700); err != nil {
		t.Fatal(err)
	}

	env := make([]string, 0, len(baseEnv)+4)
	for _, kv := range baseEnv {
		if strings.HasPrefix(kv, "PG") {
			continue
		}
		env = append(env, kv)
	}
	env = append(env,
		"PGHOST="+sockDir,
		"PGUSER=postgres",
		"PGDATABASE=postgres",
		"TZ=UTC",
	)

	runCmd(t, env, "initdb",
		"--pgdata="+dataDir,
		"--no-instructions",
		"--auth=trust",
		"--username=postgres",
		"--encoding=UTF8",
		"--locale=C",
	)
	runCmd(t, env, "pg_ctl",
		"-D", dataDir,
		"-l", logFile,
		"-w",
		"-o", fmt.Sprintf("-k %s -c listen_addresses= -c jit=off -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c shared_buffers=16MB -c max_connections=25", sockDir),
		"start",
	)
	t.Cleanup(func() {
		stop := exec.Command("pg_ctl", "-D", dataDir, "-m", "immediate", "-w", "stop")
		stop.Env = env
		_ = stop.Run()
	})

	runCmd(t, env, "createdb", "logbook_contract_template")
	migEnv := append(append([]string(nil), env...), "PGDATABASE=logbook_contract_template")
	runCmd(t, migEnv, "sh", "migrate.sh")

	return &pgCluster{env: env, sock: sockDir}
}

func (c *pgCluster) newDatabase(t *testing.T) string {
	t.Helper()
	name := fmt.Sprintf("contract_ex_%d", c.seq.Add(1))
	runCmd(t, c.env, "createdb", "--template=logbook_contract_template", name)
	t.Cleanup(func() {
		drop := exec.Command("dropdb", "--if-exists", "--force", name)
		drop.Env = c.env
		_ = drop.Run()
	})
	return name
}

func (c *pgCluster) psql(db, role, sqlText string) (string, error) {
	var script strings.Builder
	script.WriteString("SET TIME ZONE 'UTC';\n")
	if role != "" {
		script.WriteString("SET ROLE " + role + ";\n")
	}
	script.WriteString(sqlText)
	if !strings.HasSuffix(sqlText, "\n") {
		script.WriteByte('\n')
	}

	cmd := exec.Command("psql", "-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", "-d", db)
	cmd.Env = c.env
	cmd.Stdin = strings.NewReader(script.String())
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimSpace(stdout.String()), nil
}

func runCmd(t *testing.T, env []string, name string, args ...string) string {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %v failed: %v\n%s", name, args, err, out)
	}
	return string(out)
}

func sqlLit(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func sqlNullableLit(s string) string {
	if s == "" {
		return "NULL"
	}
	return sqlLit(s)
}

func mapSQLError(err error) *problem {
	if err == nil {
		return nil
	}
	msg := err.Error()
	switch {
	case strings.Contains(msg, "statement timeout"):
		return probStoreSlow
	case strings.Contains(msg, "E_PARSE:"):
		return probLogbookRefused
	case strings.Contains(msg, "E_NEEDS_SUBTOOL:"):
		return probLogbookUnfamiliar
	default:
		return probUnexpected
	}
}

type logbookContractHarness struct {
	cluster   *pgCluster
	db        string
	now       time.Time
	condition string
	// Incident details queued for Bellbuoy on an item (worker and error code).
	incidents map[string]incidentInfo
}

type incidentInfo struct {
	Worker string
	Code   string
	State  string
}

func newHarness(t *testing.T, cluster *pgCluster, seed []seedItem) *logbookContractHarness {
	t.Helper()
	epoch, err := time.Parse(time.RFC3339, contractEpoch)
	if err != nil {
		t.Fatal(err)
	}
	h := &logbookContractHarness{
		cluster:   cluster,
		db:        cluster.newDatabase(t),
		now:       epoch,
		incidents: map[string]incidentInfo{},
	}
	if len(seed) > 0 {
		h.seedItems(t, seed)
	}
	return h
}

func (h *logbookContractHarness) seedItems(t *testing.T, items []seedItem) {
	t.Helper()
	var b strings.Builder
	b.WriteString("BEGIN;\n")
	highest := 0
	ts := sqlLit(h.now.UTC().Format(time.RFC3339))
	for _, it := range items {
		title := "Made-up item " + it.ID
		fmt.Fprintf(&b, "INSERT INTO core.item (item_id, state, title, recorded_at) VALUES (%s, %s, %s, %s);\n",
			sqlLit(it.ID), sqlLit(it.State), sqlLit(title), ts)
		fmt.Fprintf(&b, "INSERT INTO core.ledger (item_id, actor, to_state, note, recorded_at) VALUES (%s, 'trawl', %s, 'seed', %s);\n",
			sqlLit(it.ID), sqlLit(it.State), ts)
		next, lane := it.Next, it.Lane
		if next == "" && it.State == "live" {
			next, lane = "tidegauge", "backfill"
		}
		if next != "" {
			fmt.Fprintf(&b, "INSERT INTO core.queue (worker, lane, item_id, queued_at) VALUES (%s, %s, %s, %s);\n",
				sqlLit(next), sqlLit(lane), sqlLit(it.ID), ts)
		}
		if n, err := strconv.Atoi(strings.TrimPrefix(it.ID, "PA-")); err == nil && n > highest {
			highest = n
		}
	}
	if highest > 0 {
		fmt.Fprintf(&b, "SELECT setval('core.item_number', %d);\n", highest)
	}
	b.WriteString("COMMIT;\n")
	if _, err := h.cluster.psql(h.db, "", b.String()); err != nil {
		t.Fatalf("seed items: %v", err)
	}
}

func (h *logbookContractHarness) arrange(t *testing.T, cond string) {
	t.Helper()
	h.condition = cond
	if cond == "the queue says sextant is next for an item that is live" {
		ts := sqlLit(h.now.UTC().Format(time.RFC3339))
		sql := fmt.Sprintf(`BEGIN;
INSERT INTO core.item (item_id, state, title, recorded_at) VALUES ('PA-0001', 'live', 'Made-up item PA-0001', %s);
INSERT INTO core.ledger (item_id, actor, to_state, note, recorded_at) VALUES ('PA-0001', 'trawl', 'live', 'seed', %s);
INSERT INTO core.queue (worker, lane, item_id, queued_at) VALUES ('sextant', 'normal', 'PA-0001', %s);
COMMIT;`, ts, ts, ts)
		if _, err := h.cluster.psql(h.db, "", sql); err != nil {
			t.Fatalf("arrange inconsistent queue row: %v", err)
		}
	}
}

func (h *logbookContractHarness) checkStoreCondition() *problem {
	switch h.condition {
	case "":
		return nil
	case "logbook takes too long":
		_, err := h.cluster.psql(h.db, "muster", "BEGIN; SET LOCAL statement_timeout = '1ms'; SELECT pg_sleep(0.05); COMMIT;")
		return mapSQLError(err)
	case "logbook fails in a way nothing provides for":
		return probUnexpected
	case "logbook refuses a field":
		// Trigger Logbook's real core.check_item E_PARSE refusal as muster.
		_, err := h.cluster.psql(h.db, "muster", "INSERT INTO core.item (state, title) VALUES ('discovered', '');")
		return mapSQLError(err)
	case "logbook has no rule for a value":
		// Trigger Logbook's real core.check_item E_NEEDS_SUBTOOL refusal as muster.
		_, err := h.cluster.psql(h.db, "muster", "INSERT INTO core.item (state, title) VALUES ('unheard_of', 'Sample');")
		return mapSQLError(err)
	case "the queue says sextant is next for an item that is live":
		return nil
	default:
		return probUnexpected
	}
}

func (h *logbookContractHarness) dispatch(t *testing.T, req contractRequest) (int, []byte, string) {
	t.Helper()

	allowedMethod, knownPath := map[string]string{
		"/healthz":          "GET",
		"/v1/feed":          "GET",
		"/v1/items":         "POST",
		"/v1/edits":         "POST",
		"/v1/lease":         "POST",
		"/v1/heartbeat":     "POST",
		"/v1/complete":      "POST",
		"/v1/fail":          "POST",
		"/v1/needs_subtool": "POST",
		"/v1/release":       "POST",
		"/v1/health":        "POST",
	}[req.Path]
	if !knownPath {
		return refusalResponse(probNoSuchCall)
	}
	if req.Method != allowedMethod {
		return refusalResponse(probWrongMethod)
	}
	if req.Path == "/healthz" {
		if _, err := h.cluster.psql(h.db, "muster", "SELECT 1;"); err != nil {
			return refusalResponse(mapSQLError(err))
		}
		return jsonResponse(http.StatusOK, `{"status":"ok"}`)
	}
	if h.condition == "every place for a call in flight is taken" {
		return refusalResponse(probBusy)
	}
	if req.As == "" {
		return refusalResponse(probNoCredential)
	}
	if h.condition == "the cluster does not answer the identity check in time" {
		return refusalResponse(probIdentitySlow)
	}
	if !callerAllowed(req.Path, req.As) {
		return refusalResponse(probNotYourCall)
	}

	if req.Method == "GET" && req.Path == "/v1/feed" {
		return h.handleFeed()
	}

	if req.ContentType != nil && *req.ContentType != "application/json" {
		return refusalResponse(probWrongType)
	}

	rawBody, err := requestPayloadBytes(req)
	if err != nil {
		return refusalResponse(probNotJSON)
	}
	maxBytes := 65536
	if req.Path == "/v1/edits" {
		maxBytes = 4096
	} else if req.Path == "/v1/complete" && req.As == "waybill" {
		maxBytes = 262144
	}
	if len(rawBody) > maxBytes {
		return refusalResponse(probTooLarge)
	}

	switch req.Path {
	case "/v1/items":
		return h.handleItems(req.As, rawBody)
	case "/v1/edits":
		return h.handleEdits(rawBody)
	case "/v1/lease":
		return h.handleLease(req.As, rawBody)
	case "/v1/heartbeat":
		return h.handleHeartbeat(req.As, rawBody)
	case "/v1/complete":
		return h.handleComplete(req.As, rawBody)
	case "/v1/fail":
		return h.handleFail(req.As, rawBody)
	case "/v1/needs_subtool":
		return h.handleNeedsSubtool(req.As, rawBody)
	case "/v1/release":
		return h.handleRelease(rawBody)
	case "/v1/health":
		return h.handleHealth(rawBody)
	default:
		return refusalResponse(probNoSuchCall)
	}
}

func callerAllowed(path, as string) bool {
	switch path {
	case "/v1/items":
		return as == "trawl" || as == "conn"
	case "/v1/edits", "/v1/feed":
		return as == "conn"
	case "/v1/release":
		return as == "countersign"
	case "/v1/health":
		return as == "shipkeeper"
	case "/v1/lease", "/v1/heartbeat", "/v1/complete", "/v1/fail", "/v1/needs_subtool":
		return workerCallers[as]
	default:
		return false
	}
}

func requestPayloadBytes(req contractRequest) ([]byte, error) {
	if req.Raw != nil {
		return []byte(*req.Raw), nil
	}
	if len(req.Body) == 0 {
		return nil, nil
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, req.Body); err != nil {
		return []byte(req.Body), nil
	}
	return buf.Bytes(), nil
}

func decodeStrictJSON(raw []byte, allowed map[string]bool) (map[string]json.RawMessage, *problem) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil, probNotJSON
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	var obj map[string]json.RawMessage
	if err := dec.Decode(&obj); err != nil || obj == nil {
		return nil, probNotJSON
	}
	var extra any
	if err := dec.Decode(&extra); err == nil {
		return nil, probNotJSON
	}
	for k := range obj {
		if !allowed[k] {
			return nil, probUnknownField
		}
	}
	rawContract, ok := obj["contract"]
	if !ok {
		return nil, probMissingField
	}
	var ver string
	if err := json.Unmarshal(rawContract, &ver); err != nil || ver == "" {
		if ver == "" && string(rawContract) == `""` {
			return nil, probMissingField
		}
		return nil, probBadField
	}
	if ver != "v1" {
		return nil, probUnknownContract
	}
	return obj, nil
}

func decodeRequiredString(obj map[string]json.RawMessage, key string) (string, *problem) {
	raw, ok := obj[key]
	if !ok {
		return "", probMissingField
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", probBadField
	}
	if s == "" {
		return "", probMissingField
	}
	return s, nil
}

func decodeOptionalString(obj map[string]json.RawMessage, key string, presentRequired bool) (string, *problem) {
	raw, ok := obj[key]
	if !ok {
		if presentRequired {
			return "", probMissingField
		}
		return "", nil
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", probBadField
	}
	return s, nil
}

func decodeOptionalResult(obj map[string]json.RawMessage) (string, *problem) {
	raw, ok := obj["result"]
	if !ok {
		return "", nil
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil || m == nil {
		return "", probBadField
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, raw); err != nil {
		return "", probBadField
	}
	return compact.String(), nil
}

func refusalResponse(p *problem) (int, []byte, string) {
	body := fmt.Sprintf(`{"error":%q,"cause":%q,"reason":%q}`+"\n", p.Code, p.Cause, p.Reason)
	return p.Status, []byte(body), ""
}

func jsonResponse(status int, raw string) (int, []byte, string) {
	return status, []byte(raw + "\n"), ""
}

func visitorHMAC(day, ip string) (string, bool) {
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return "", false
	}
	mac := hmac.New(sha256.New, []byte("contract-v1-test-salt"))
	mac.Write([]byte(day))
	mac.Write([]byte{0})
	mac.Write([]byte(addr.String()))
	return hex.EncodeToString(mac.Sum(nil)), true
}

var powTokenRe = regexp.MustCompile(`^([0-9]{4}-[0-9]{2}-[0-9]{2})\.([0-9a-f]{1,32})$`)

func verifyPoW(token, a, b, c string, bitsNeeded int, now time.Time) bool {
	m := powTokenRe.FindStringSubmatch(token)
	if m == nil {
		return false
	}
	day, nonce := m[1], m[2]
	utc := now.UTC()
	if day != utc.Format("2006-01-02") && day != utc.AddDate(0, 0, -1).Format("2006-01-02") {
		return false
	}
	h := sha256.New()
	for _, part := range []string{"muster-pow-v1", day, a, b, c} {
		h.Write([]byte(part))
		h.Write([]byte{0})
	}
	h.Write([]byte(nonce))
	var sum [sha256.Size]byte
	h.Sum(sum[:0])
	zeros := 0
	for _, x := range sum {
		if x != 0 {
			zeros += bits.LeadingZeros8(x)
			break
		}
		zeros += 8
	}
	return zeros >= bitsNeeded
}

func stripMarkup(s string) string {
	for {
		next := stripMarkupOnce(s)
		if next == s {
			return strings.TrimSpace(next)
		}
		s = next
	}
}

func stripMarkupOnce(s string) string {
	var out strings.Builder
	for i := 0; i < len(s); {
		if s[i] != '<' {
			out.WriteByte(s[i])
			i++
			continue
		}
		rest := s[i:]
		if strings.HasPrefix(rest, "<!--") {
			end := strings.Index(rest[4:], "-->")
			if end < 0 {
				return out.String()
			}
			i += 4 + end + 3
			continue
		}
		if len(rest) < 2 || !isTagStart(rest[1]) {
			out.WriteByte(s[i])
			i++
			continue
		}
		end := findTagEnd(rest)
		if end < 0 {
			return out.String()
		}
		name := readTagName(rest)
		i += end + 1
		if rest[1] != '/' && (name == "script" || name == "style") {
			lower := strings.ToLower(s[i:])
			closeIdx := strings.Index(lower, "</"+name)
			if closeIdx < 0 {
				return out.String()
			}
			after := findTagEnd(s[i+closeIdx:])
			if after < 0 {
				return out.String()
			}
			i += closeIdx + after + 1
		}
	}
	return out.String()
}

func isTagStart(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '/' || c == '!' || c == '?'
}

func findTagEnd(s string) int {
	var quote byte
	for i := 1; i < len(s); i++ {
		c := s[i]
		switch {
		case quote != 0:
			if c == quote {
				quote = 0
			}
		case c == '"' || c == '\'':
			quote = c
		case c == '>':
			return i
		}
	}
	return -1
}

func readTagName(s string) string {
	i := 1
	if i < len(s) && s[i] == '/' {
		i++
	}
	j := i
	for j < len(s) && ((s[j] >= 'a' && s[j] <= 'z') || (s[j] >= 'A' && s[j] <= 'Z') || (s[j] >= '0' && s[j] <= '9')) {
		j++
	}
	return strings.ToLower(s[i:j])
}

func (h *logbookContractHarness) admitVisitor(ip string) (bool, *problem) {
	day := h.now.UTC().Format("2006-01-02")
	vkey, ok := visitorHMAC(day, ip)
	if !ok {
		return false, probBadField
	}
	sql := fmt.Sprintf(`BEGIN;
INSERT INTO core.submission_count (submission_day, visitor_key, submissions)
VALUES (%s, %s, 1)
ON CONFLICT (submission_day, visitor_key)
DO UPDATE SET submissions = core.submission_count.submissions + 1
RETURNING submissions;
COMMIT;`, sqlLit(day), sqlLit(vkey))
	out, err := h.cluster.psql(h.db, "muster", sql)
	if err != nil {
		return false, mapSQLError(err)
	}
	count, _ := strconv.Atoi(strings.TrimSpace(out))
	return count <= dailyVisitorLimit, nil
}

func (h *logbookContractHarness) handleItems(as string, raw []byte) (int, []byte, string) {
	obj, prob := decodeStrictJSON(raw, map[string]bool{
		"contract": true, "source": true, "title": true, "address": true,
		"result": true, "pow": true, "visitor": true,
	})
	if prob != nil {
		return refusalResponse(prob)
	}
	source, prob := decodeRequiredString(obj, "source")
	if prob != nil {
		return refusalResponse(prob)
	}
	title, prob := decodeRequiredString(obj, "title")
	if prob != nil {
		return refusalResponse(prob)
	}
	address, prob := decodeRequiredString(obj, "address")
	if prob != nil {
		return refusalResponse(prob)
	}
	resJSON, prob := decodeOptionalResult(obj)
	if prob != nil {
		return refusalResponse(prob)
	}
	if resJSON != "" && as != "trawl" {
		return refusalResponse(probBadField)
	}
	pow, prob := decodeOptionalString(obj, "pow", false)
	if prob != nil {
		return refusalResponse(prob)
	}
	visitor, prob := decodeOptionalString(obj, "visitor", false)
	if prob != nil {
		return refusalResponse(prob)
	}

	lane, knownSource := sourceLanes[source]
	if !knownSource {
		// Verify Logbook's own check_item also refuses an unfamiliar source slug with E_NEEDS_SUBTOOL.
		_, err := h.cluster.psql(h.db, "muster", fmt.Sprintf(
			"INSERT INTO core.item (state, title, source) VALUES ('discovered', 'Sample', %s);",
			sqlLit(source),
		))
		if err == nil || !strings.Contains(err.Error(), "E_NEEDS_SUBTOOL:") {
			return refusalResponse(probUnexpected)
		}
		return refusalResponse(probUnknownSource)
	}

	if source == "site-form" {
		if pow == "" || visitor == "" {
			return refusalResponse(probMissingField)
		}
		if _, err := netip.ParseAddr(visitor); err != nil {
			return refusalResponse(probBadField)
		}
		if !verifyPoW(pow, source, title, address, defaultPoWBits, h.now) {
			return refusalResponse(probBadProof)
		}
	} else if pow != "" || visitor != "" {
		return refusalResponse(probBadField)
	}

	cleanTitle := stripMarkup(title)
	if cleanTitle == "" {
		return refusalResponse(probNothingLeft)
	}
	if p := h.checkStoreCondition(); p != nil {
		return refusalResponse(p)
	}

	if source == "site-form" {
		ok, p := h.admitVisitor(visitor)
		if p != nil {
			return refusalResponse(p)
		}
		if !ok {
			return refusalResponse(probRateLimited)
		}
	}

	// Check if an item at this address is already on record.
	existing, err := h.cluster.psql(h.db, "muster", fmt.Sprintf(
		"SELECT item_id || '|' || state FROM core.item WHERE address = %s ORDER BY item_id LIMIT 1;",
		sqlLit(address),
	))
	if err != nil {
		return refusalResponse(mapSQLError(err))
	}
	if existing != "" {
		parts := strings.SplitN(existing, "|", 2)
		body := fmt.Sprintf(`{"id":%q,"state":%q,"duplicate":true}`, parts[0], parts[1])
		return jsonResponse(http.StatusOK, body)
	}

	ts := sqlLit(h.now.UTC().Format(time.RFC3339))
	var tx strings.Builder
	tx.WriteString("BEGIN;\n")
	fmt.Fprintf(&tx, "WITH ins AS (\n  INSERT INTO core.item (state, title, address, source) VALUES ('discovered', %s, %s, %s) RETURNING item_id\n),\n",
		sqlLit(cleanTitle), sqlLit(address), sqlLit(source))
	fmt.Fprintf(&tx, "led AS (\n  INSERT INTO core.ledger (item_id, actor, to_state, note, recorded_at) SELECT item_id, %s, 'discovered', 'intake', %s FROM ins\n),\n",
		sqlLit(as), ts)
	if resJSON != "" {
		fmt.Fprintf(&tx, "res AS (\n  INSERT INTO core.result (item_id, worker, payload, recorded_at) SELECT item_id, %s, %s::jsonb, %s FROM ins\n),\n",
			sqlLit(as), sqlLit(resJSON), ts)
	}
	fmt.Fprintf(&tx, "q AS (\n  INSERT INTO core.queue (worker, lane, item_id, queued_at) SELECT 'trawl', %s, item_id, %s FROM ins\n)\n",
		sqlLit(lane), ts)
	tx.WriteString("SELECT item_id FROM ins;\nCOMMIT;\n")

	itemID, err := h.cluster.psql(h.db, "muster", tx.String())
	if err != nil {
		return refusalResponse(mapSQLError(err))
	}
	itemID = strings.TrimSpace(strings.Split(itemID, "\n")[0])
	body := fmt.Sprintf(`{"id":%q,"state":"discovered","next":"trawl"}`, itemID)
	return jsonResponse(http.StatusCreated, body)
}

func (h *logbookContractHarness) handleEdits(raw []byte) (int, []byte, string) {
	obj, prob := decodeStrictJSON(raw, map[string]bool{
		"contract": true, "target": true, "change": true,
		"reason": true, "pow": true, "honeypot": true, "source": true,
	})
	if prob != nil {
		return refusalResponse(prob)
	}
	target, prob := decodeRequiredString(obj, "target")
	if prob != nil {
		return refusalResponse(prob)
	}
	change, prob := decodeRequiredString(obj, "change")
	if prob != nil {
		return refusalResponse(prob)
	}
	reason, prob := decodeOptionalString(obj, "reason", false)
	if prob != nil {
		return refusalResponse(prob)
	}
	pow, prob := decodeRequiredString(obj, "pow")
	if prob != nil {
		return refusalResponse(prob)
	}
	honeypot, prob := decodeOptionalString(obj, "honeypot", true)
	if prob != nil {
		return refusalResponse(prob)
	}
	sourceIP, prob := decodeRequiredString(obj, "source")
	if prob != nil {
		return refusalResponse(prob)
	}
	if _, err := netip.ParseAddr(sourceIP); err != nil {
		return refusalResponse(probBadField)
	}
	if !verifyPoW(pow, target, change, reason, defaultPoWBits, h.now) {
		return refusalResponse(probBadProof)
	}
	if honeypot != "" {
		return http.StatusNoContent, nil, ""
	}

	if p := h.checkStoreCondition(); p != nil {
		return refusalResponse(p)
	}
	ok, p := h.admitVisitor(sourceIP)
	if p != nil {
		return refusalResponse(p)
	}
	if !ok {
		return refusalResponse(probRateLimited)
	}

	owner, known := sampleOwnershipMap[target]
	if !known {
		return refusalResponse(probUnknownTarget)
	}
	cleanChange := stripMarkup(change)
	cleanReason := stripMarkup(reason)
	if cleanChange == "" {
		return refusalResponse(probNothingLeft)
	}

	ts := sqlLit(h.now.UTC().Format(time.RFC3339))
	sql := fmt.Sprintf(`BEGIN;
WITH ins AS (
  INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload, reason, file_path, status, submitted_at)
  VALUES (%s, %s, %s, %s, %s, %s, 'pending_approval', %s)
  RETURNING proposal_id
),
led AS (
  INSERT INTO core.ledger (proposal_id, actor, to_state, recorded_at)
  SELECT proposal_id, 'muster', 'pending_approval', %s FROM ins
),
q AS (
  INSERT INTO core.queue (worker, lane, proposal_id, queued_at)
  SELECT 'countersign', 'normal', proposal_id, %s FROM ins
)
SELECT proposal_id FROM ins;
COMMIT;`,
		sqlLit(target), sqlLit(owner.Repository), sqlLit(owner.Kind),
		sqlLit(cleanChange), sqlNullableLit(cleanReason), sqlLit(owner.File),
		ts, ts, ts,
	)
	out, err := h.cluster.psql(h.db, "muster", sql)
	if err != nil {
		return refusalResponse(mapSQLError(err))
	}
	propNum, _ := strconv.ParseUint(strings.TrimSpace(strings.Split(out, "\n")[0]), 10, 64)
	propID := fmt.Sprintf("EP-%04d", propNum)
	return jsonResponse(http.StatusAccepted, fmt.Sprintf(`{"id":%q,"status":"pending_approval"}`, propID))
}

func makeLeaseToken(queueID int64, attempt int) string {
	u := uint64(queueID)
	return fmt.Sprintf("%08x-0000-0000-%04x-%012x", uint32(attempt), u>>48, u&0xffffffffffff)
}

func formatLeaseID(kind, id string, queueID int64, attempt int) string {
	if kind == "incident" {
		return fmt.Sprintf("incident:%s.%d.%d", id, queueID, attempt)
	}
	return fmt.Sprintf("%s.%d.%d", id, queueID, attempt)
}

var leaseIDRe = regexp.MustCompile(`^(incident:)?(PA-(?:[0-9]{4}|[1-9][0-9]{4,8})|EP-(?:[0-9]{4}|[1-9][0-9]{4,8}))\.([1-9][0-9]*)\.([1-9][0-9]*)$`)

type parsedLease struct {
	Incident bool
	Subject  string
	IsProp   bool
	PropNum  int64
	QueueID  int64
	Attempt  int
}

func parseLeaseID(s string) (parsedLease, bool) {
	m := leaseIDRe.FindStringSubmatch(s)
	if m == nil {
		return parsedLease{}, false
	}
	inc := m[1] == "incident:"
	subj := m[2]
	isProp := strings.HasPrefix(subj, "EP-")
	if inc && isProp {
		return parsedLease{}, false
	}
	qID, err1 := strconv.ParseInt(m[3], 10, 64)
	att, err2 := strconv.Atoi(m[4])
	if err1 != nil || err2 != nil {
		return parsedLease{}, false
	}
	var propNum int64
	if isProp {
		propNum, _ = strconv.ParseInt(strings.TrimPrefix(subj, "EP-"), 10, 64)
	}
	return parsedLease{
		Incident: inc,
		Subject:  subj,
		IsProp:   isProp,
		PropNum:  propNum,
		QueueID:  qID,
		Attempt:  att,
	}, true
}

func workerHoldsState(worker, kind, state string) bool {
	if kind == "incident" {
		return worker == "bellbuoy"
	}
	for _, r := range contractRoutes {
		if r.Worker == worker && r.Kind == kind && r.From == state {
			return true
		}
	}
	return false
}

func findRoute(worker, kind, from, to string) (routeRule, bool) {
	for _, r := range contractRoutes {
		if r.Worker == worker && r.Kind == kind && r.From == from && r.To == to {
			return r, true
		}
	}
	return routeRule{}, false
}

func (h *logbookContractHarness) handleLease(worker string, raw []byte) (int, []byte, string) {
	if _, prob := decodeStrictJSON(raw, map[string]bool{"contract": true}); prob != nil {
		return refusalResponse(prob)
	}
	if p := h.checkStoreCondition(); p != nil {
		return refusalResponse(p)
	}

	nowStr := h.now.UTC().Format(time.RFC3339)
	query := fmt.Sprintf(`SELECT q.queue_id, q.lane, coalesce(q.item_id, ''), coalesce(q.proposal_id::text, ''), q.attempt
FROM core.queue q
WHERE q.worker = %s
  AND NOT q.held
  AND q.queued_at <= %s
  AND (q.lease_token IS NULL OR q.leased_until <= %s)
ORDER BY q.lane_rank, q.queue_id
LIMIT 1;`, sqlLit(worker), sqlLit(nowStr), sqlLit(nowStr))

	row, err := h.cluster.psql(h.db, "muster", query)
	if err != nil {
		return refusalResponse(mapSQLError(err))
	}
	if row == "" {
		return http.StatusNoContent, nil, ""
	}
	cols := strings.Split(row, "|")
	queueID, _ := strconv.ParseInt(cols[0], 10, 64)
	lane := cols[1]
	itemID := cols[2]
	propIDStr := cols[3]
	prevAttempt, _ := strconv.Atoi(cols[4])

	var kind, subjectID, state string
	var propJSON string
	if itemID != "" {
		if worker == "bellbuoy" {
			kind = "incident"
		} else {
			kind = "item"
		}
		subjectID = itemID
		st, err := h.cluster.psql(h.db, "muster", fmt.Sprintf("SELECT state FROM core.item WHERE item_id = %s;", sqlLit(itemID)))
		if err != nil {
			return refusalResponse(mapSQLError(err))
		}
		state = strings.TrimSpace(st)
	} else {
		kind = "proposal"
		propNum, _ := strconv.ParseInt(propIDStr, 10, 64)
		subjectID = fmt.Sprintf("EP-%04d", propNum)
		pRow, err := h.cluster.psql(h.db, "muster", fmt.Sprintf(`SELECT status, json_build_object(
  'target', element_id,
  'repository', owner_repo,
  'file', coalesce(file_path, ''),
  'edit_kind', edit_class,
  'change', payload,
  'reason', coalesce(reason, '')
)::text
FROM core.edit_proposal WHERE proposal_id = %d;`, propNum))
		if err != nil {
			return refusalResponse(mapSQLError(err))
		}
		parts := strings.SplitN(pRow, "|", 2)
		state = parts[0]
		propJSON = parts[1]
	}

	if !workerHoldsState(worker, kind, state) {
		// Inconsistent stored record: set the queue row aside as held in Logbook and refuse with 500 bad_record.
		_, _ = h.cluster.psql(h.db, "muster", fmt.Sprintf(
			"UPDATE core.queue SET held = true, lease_token = NULL, leased_until = NULL, heartbeat_at = NULL WHERE queue_id = %d;",
			queueID,
		))
		return refusalResponse(probBadRecord)
	}

	attempt := prevAttempt + 1
	expires := h.now.Add(defaultLeaseWindow).UTC()
	token := makeLeaseToken(queueID, attempt)
	_, err = h.cluster.psql(h.db, "muster", fmt.Sprintf(`UPDATE core.queue
SET attempt = %d,
    lease_token = %s::uuid,
    leased_until = %s,
    heartbeat_at = %s
WHERE queue_id = %d;`,
		attempt, sqlLit(token), sqlLit(expires.Format(time.RFC3339)), sqlLit(nowStr), queueID,
	))
	if err != nil {
		return refusalResponse(mapSQLError(err))
	}

	// Fetch any stored worker results for this subject from core.result.
	var resQuery string
	if itemID != "" && kind == "item" {
		resQuery = fmt.Sprintf(
			"SELECT coalesce(json_object_agg(worker, payload ORDER BY worker)::text, '') FROM core.result WHERE item_id = %s;",
			sqlLit(itemID),
		)
	} else if kind == "proposal" {
		resQuery = fmt.Sprintf(
			"SELECT coalesce(json_object_agg(worker, payload ORDER BY worker)::text, '') FROM core.result WHERE proposal_id = %s;",
			propIDStr,
		)
	}
	var resultsObj string
	if resQuery != "" {
		rOut, err := h.cluster.psql(h.db, "muster", resQuery)
		if err != nil {
			return refusalResponse(mapSQLError(err))
		}
		var buf bytes.Buffer
		if rOut != "" && json.Compact(&buf, []byte(rOut)) == nil && buf.String() != "{}" {
			resultsObj = buf.String()
		}
	}

	leaseStr := formatLeaseID(kind, subjectID, queueID, attempt)
	var out strings.Builder
	fmt.Fprintf(&out, `{"lease":%q,"kind":%q,"id":%q,"state":%q,"lane":%q,"attempt":%d,"expires":%q`,
		leaseStr, kind, subjectID, state, lane, attempt, expires.Format(time.RFC3339))
	if resultsObj != "" {
		fmt.Fprintf(&out, `,"results":%s`, resultsObj)
	}
	if kind == "proposal" {
		var compactProp bytes.Buffer
		_ = json.Compact(&compactProp, []byte(propJSON))
		fmt.Fprintf(&out, `,"proposal":%s`, compactProp.String())
	}
	if kind == "incident" {
		inc := h.incidents[itemID]
		fmt.Fprintf(&out, `,"incident":{"id":%q,"worker":%q,"code":%q,"state":%q}`,
			itemID, inc.Worker, inc.Code, inc.State)
	}
	out.WriteByte('}')
	return jsonResponse(http.StatusOK, out.String())
}

func (h *logbookContractHarness) verifyHeldLease(worker string, pl parsedLease) (string, *problem) {
	nowStr := h.now.UTC().Format(time.RFC3339)
	token := makeLeaseToken(pl.QueueID, pl.Attempt)
	row, err := h.cluster.psql(h.db, "muster", fmt.Sprintf(`SELECT worker, coalesce(item_id, ''), coalesce(proposal_id::text, '')
FROM core.queue
WHERE queue_id = %d
  AND NOT held
  AND attempt = %d
  AND lease_token = %s::uuid
  AND leased_until > %s;`,
		pl.QueueID, pl.Attempt, sqlLit(token), sqlLit(nowStr),
	))
	if err != nil {
		return "", mapSQLError(err)
	}
	if row == "" {
		return "", probLeaseNotHeld
	}
	cols := strings.Split(row, "|")
	if cols[0] != worker {
		return "", probLeaseNotHeld
	}
	if pl.IsProp {
		if cols[2] != strconv.FormatInt(pl.PropNum, 10) {
			return "", probLeaseNotHeld
		}
		st, err := h.cluster.psql(h.db, "muster", fmt.Sprintf("SELECT status FROM core.edit_proposal WHERE proposal_id = %d;", pl.PropNum))
		if err != nil {
			return "", mapSQLError(err)
		}
		return strings.TrimSpace(st), nil
	}
	if cols[1] != pl.Subject || (pl.Incident != (worker == "bellbuoy")) {
		return "", probLeaseNotHeld
	}
	st, err := h.cluster.psql(h.db, "muster", fmt.Sprintf("SELECT state FROM core.item WHERE item_id = %s;", sqlLit(pl.Subject)))
	if err != nil {
		return "", mapSQLError(err)
	}
	return strings.TrimSpace(st), nil
}

func (h *logbookContractHarness) handleHeartbeat(worker string, raw []byte) (int, []byte, string) {
	obj, prob := decodeStrictJSON(raw, map[string]bool{"contract": true, "lease": true})
	if prob != nil {
		return refusalResponse(prob)
	}
	leaseStr, prob := decodeRequiredString(obj, "lease")
	if prob != nil {
		return refusalResponse(prob)
	}
	pl, ok := parseLeaseID(leaseStr)
	if !ok {
		return refusalResponse(probBadField)
	}
	if p := h.checkStoreCondition(); p != nil {
		return refusalResponse(p)
	}
	if _, p := h.verifyHeldLease(worker, pl); p != nil {
		return refusalResponse(p)
	}
	nowStr := h.now.UTC().Format(time.RFC3339)
	expires := h.now.Add(defaultLeaseWindow).UTC()
	_, err := h.cluster.psql(h.db, "muster", fmt.Sprintf(
		"UPDATE core.queue SET leased_until = %s, heartbeat_at = %s WHERE queue_id = %d;",
		sqlLit(expires.Format(time.RFC3339)), sqlLit(nowStr), pl.QueueID,
	))
	if err != nil {
		return refusalResponse(mapSQLError(err))
	}
	return jsonResponse(http.StatusOK, fmt.Sprintf(`{"lease":%q,"expires":%q}`, leaseStr, expires.Format(time.RFC3339)))
}

func (h *logbookContractHarness) recordLeaseOutcomeTx(pl parsedLease, leaseStr, worker, callName, callArg, ackState, ackNext string, ackHeld bool, ts string) string {
	if pl.IsProp {
		return fmt.Sprintf(`INSERT INTO core.lease_outcome (proposal_id, is_incident, lease, worker, call_name, call_arg, ack_state, ack_next, ack_held, recorded_at)
VALUES (%d, false, %s, %s, %s, %s, %s, %s, %t, %s)
ON CONFLICT (proposal_id) WHERE proposal_id IS NOT NULL DO UPDATE
SET lease = EXCLUDED.lease, worker = EXCLUDED.worker, call_name = EXCLUDED.call_name,
    call_arg = EXCLUDED.call_arg, ack_state = EXCLUDED.ack_state, ack_next = EXCLUDED.ack_next,
    ack_held = EXCLUDED.ack_held, recorded_at = EXCLUDED.recorded_at;`,
			pl.PropNum, sqlLit(leaseStr), sqlLit(worker), sqlLit(callName),
			sqlNullableLit(callArg), sqlLit(ackState), sqlNullableLit(ackNext), ackHeld, ts,
		)
	}
	return fmt.Sprintf(`INSERT INTO core.lease_outcome (item_id, is_incident, lease, worker, call_name, call_arg, ack_state, ack_next, ack_held, recorded_at)
VALUES (%s, %t, %s, %s, %s, %s, %s, %s, %t, %s)
ON CONFLICT (item_id, is_incident) WHERE item_id IS NOT NULL DO UPDATE
SET lease = EXCLUDED.lease, worker = EXCLUDED.worker, call_name = EXCLUDED.call_name,
    call_arg = EXCLUDED.call_arg, ack_state = EXCLUDED.ack_state, ack_next = EXCLUDED.ack_next,
    ack_held = EXCLUDED.ack_held, recorded_at = EXCLUDED.recorded_at;`,
		sqlLit(pl.Subject), pl.Incident, sqlLit(leaseStr), sqlLit(worker), sqlLit(callName),
		sqlNullableLit(callArg), sqlLit(ackState), sqlNullableLit(ackNext), ackHeld, ts,
	)
}

func (h *logbookContractHarness) handleComplete(worker string, raw []byte) (int, []byte, string) {
	obj, prob := decodeStrictJSON(raw, map[string]bool{
		"contract": true, "lease": true, "state": true, "result": true,
	})
	if prob != nil {
		return refusalResponse(prob)
	}
	leaseStr, prob := decodeRequiredString(obj, "lease")
	if prob != nil {
		return refusalResponse(prob)
	}
	toState, prob := decodeRequiredString(obj, "state")
	if prob != nil {
		return refusalResponse(prob)
	}
	resJSON, prob := decodeOptionalResult(obj)
	if prob != nil {
		return refusalResponse(prob)
	}
	pl, ok := parseLeaseID(leaseStr)
	if !ok {
		return refusalResponse(probBadField)
	}
	if p := h.checkStoreCondition(); p != nil {
		return refusalResponse(p)
	}
	curState, p := h.verifyHeldLease(worker, pl)
	if p != nil {
		return refusalResponse(p)
	}

	ts := sqlLit(h.now.UTC().Format(time.RFC3339))
	if pl.Incident {
		if toState != curState {
			return refusalResponse(probMoveNotAllowed)
		}
		var tx strings.Builder
		tx.WriteString("BEGIN;\n")
		fmt.Fprintf(&tx, "DELETE FROM core.queue WHERE queue_id = %d;\n", pl.QueueID)
		tx.WriteString(h.recordLeaseOutcomeTx(pl, leaseStr, worker, "complete", toState, curState, "", false, ts) + "\n")
		tx.WriteString("COMMIT;\n")
		if _, err := h.cluster.psql(h.db, "muster", tx.String()); err != nil {
			return refusalResponse(mapSQLError(err))
		}
		return jsonResponse(http.StatusOK, fmt.Sprintf(`{"id":%q,"state":%q}`, pl.Subject, curState))
	}

	kind := "item"
	if pl.IsProp {
		kind = "proposal"
	}
	route, allowed := findRoute(worker, kind, curState, toState)
	if !allowed {
		return refusalResponse(probMoveNotAllowed)
	}

	var tx strings.Builder
	tx.WriteString("BEGIN;\n")
	fmt.Fprintf(&tx, "DELETE FROM core.queue WHERE queue_id = %d;\n", pl.QueueID)
	if pl.IsProp {
		if toState != curState {
			fmt.Fprintf(&tx, "UPDATE core.edit_proposal SET status = %s, decided_at = COALESCE(decided_at, %s) WHERE proposal_id = %d;\n",
				sqlLit(toState), ts, pl.PropNum)
			fmt.Fprintf(&tx, "INSERT INTO core.ledger (proposal_id, actor, from_state, to_state, recorded_at) VALUES (%d, %s, %s, %s, %s);\n",
				pl.PropNum, sqlLit(worker), sqlLit(curState), sqlLit(toState), ts)
		}
		if resJSON != "" {
			fmt.Fprintf(&tx, `INSERT INTO core.result (proposal_id, worker, payload, recorded_at)
VALUES (%d, %s, %s::jsonb, %s)
ON CONFLICT (proposal_id, worker) WHERE proposal_id IS NOT NULL
DO UPDATE SET payload = EXCLUDED.payload, recorded_at = EXCLUDED.recorded_at;`+"\n",
				pl.PropNum, sqlLit(worker), sqlLit(resJSON), ts)
		}
		if route.Next != "" {
			queuedAt := h.now.Add(time.Duration(route.AfterDays) * 24 * time.Hour).UTC().Format(time.RFC3339)
			fmt.Fprintf(&tx, "INSERT INTO core.queue (worker, lane, proposal_id, queued_at) VALUES (%s, %s, %d, %s);\n",
				sqlLit(route.Next), sqlLit(route.Lane), pl.PropNum, sqlLit(queuedAt))
		}
	} else {
		if toState != curState {
			fmt.Fprintf(&tx, "UPDATE core.item SET state = %s WHERE item_id = %s;\n", sqlLit(toState), sqlLit(pl.Subject))
		}
		fmt.Fprintf(&tx, "INSERT INTO core.ledger (item_id, actor, from_state, to_state, note, recorded_at) VALUES (%s, %s, %s, %s, 'complete', %s);\n",
			sqlLit(pl.Subject), sqlLit(worker), sqlLit(curState), sqlLit(toState), ts)
		if resJSON != "" {
			fmt.Fprintf(&tx, `INSERT INTO core.result (item_id, worker, payload, recorded_at)
VALUES (%s, %s, %s::jsonb, %s)
ON CONFLICT (item_id, worker) WHERE item_id IS NOT NULL
DO UPDATE SET payload = EXCLUDED.payload, recorded_at = EXCLUDED.recorded_at;`+"\n",
				sqlLit(pl.Subject), sqlLit(worker), sqlLit(resJSON), ts)
		}
		if route.Next != "" {
			queuedAt := h.now.Add(time.Duration(route.AfterDays) * 24 * time.Hour).UTC().Format(time.RFC3339)
			fmt.Fprintf(&tx, "INSERT INTO core.queue (worker, lane, item_id, queued_at) VALUES (%s, %s, %s, %s);\n",
				sqlLit(route.Next), sqlLit(route.Lane), sqlLit(pl.Subject), sqlLit(queuedAt))
		}
	}
	tx.WriteString(h.recordLeaseOutcomeTx(pl, leaseStr, worker, "complete", toState, toState, route.Next, false, ts) + "\n")
	tx.WriteString("COMMIT;\n")

	if _, err := h.cluster.psql(h.db, "muster", tx.String()); err != nil {
		return refusalResponse(mapSQLError(err))
	}
	if route.Next != "" {
		return jsonResponse(http.StatusOK, fmt.Sprintf(`{"id":%q,"state":%q,"next":%q}`, pl.Subject, toState, route.Next))
	}
	return jsonResponse(http.StatusOK, fmt.Sprintf(`{"id":%q,"state":%q}`, pl.Subject, toState))
}

func (h *logbookContractHarness) handleFail(worker string, raw []byte) (int, []byte, string) {
	obj, prob := decodeStrictJSON(raw, map[string]bool{
		"contract": true, "lease": true, "code": true,
	})
	if prob != nil {
		return refusalResponse(prob)
	}
	leaseStr, prob := decodeRequiredString(obj, "lease")
	if prob != nil {
		return refusalResponse(prob)
	}
	code, prob := decodeRequiredString(obj, "code")
	if prob != nil {
		return refusalResponse(prob)
	}
	if code == "E_NEEDS_SUBTOOL" {
		return refusalResponse(probUseNeedsSubtool)
	}
	if code != "E_TIMEOUT" && code != "E_PARSE" {
		return refusalResponse(probBadField)
	}
	pl, ok := parseLeaseID(leaseStr)
	if !ok {
		return refusalResponse(probBadField)
	}
	if p := h.checkStoreCondition(); p != nil {
		return refusalResponse(p)
	}
	curState, p := h.verifyHeldLease(worker, pl)
	if p != nil {
		return refusalResponse(p)
	}

	ts := sqlLit(h.now.UTC().Format(time.RFC3339))
	var tx strings.Builder
	tx.WriteString("BEGIN;\n")
	if code == "E_TIMEOUT" {
		fmt.Fprintf(&tx, "UPDATE core.queue SET lease_token = NULL, leased_until = NULL, heartbeat_at = NULL WHERE queue_id = %d;\n", pl.QueueID)
		if !pl.IsProp && !pl.Incident {
			fmt.Fprintf(&tx, "INSERT INTO core.ledger (item_id, actor, from_state, to_state, error_code, note, recorded_at) VALUES (%s, %s, %s, %s, 'E_TIMEOUT', 'timed out', %s);\n",
				sqlLit(pl.Subject), sqlLit(worker), sqlLit(curState), sqlLit(curState), ts)
		}
		tx.WriteString(h.recordLeaseOutcomeTx(pl, leaseStr, worker, "fail", code, curState, worker, false, ts) + "\n")
		tx.WriteString("COMMIT;\n")
		if _, err := h.cluster.psql(h.db, "muster", tx.String()); err != nil {
			return refusalResponse(mapSQLError(err))
		}
		return jsonResponse(http.StatusOK, fmt.Sprintf(`{"id":%q,"state":%q,"next":%q}`, pl.Subject, curState, worker))
	}

	// E_PARSE: hold the queue step in Logbook and queue an incident for Bellbuoy when the subject is an item.
	fmt.Fprintf(&tx, "UPDATE core.queue SET held = true, lease_token = NULL, leased_until = NULL, heartbeat_at = NULL WHERE queue_id = %d;\n", pl.QueueID)
	if !pl.IsProp && !pl.Incident {
		fmt.Fprintf(&tx, "INSERT INTO core.ledger (item_id, actor, from_state, to_state, error_code, note, recorded_at) VALUES (%s, %s, %s, %s, 'E_PARSE', 'stopped on parse failure', %s);\n",
			sqlLit(pl.Subject), sqlLit(worker), sqlLit(curState), sqlLit(curState), ts)
		fmt.Fprintf(&tx, "DELETE FROM core.queue WHERE worker = 'bellbuoy' AND item_id = %s;\n", sqlLit(pl.Subject))
		fmt.Fprintf(&tx, "INSERT INTO core.queue (worker, lane, item_id, queued_at) VALUES ('bellbuoy', 'normal', %s, %s);\n",
			sqlLit(pl.Subject), ts)
		h.incidents[pl.Subject] = incidentInfo{Worker: worker, Code: "E_PARSE", State: curState}
	}
	tx.WriteString(h.recordLeaseOutcomeTx(pl, leaseStr, worker, "fail", code, curState, "", true, ts) + "\n")
	tx.WriteString("COMMIT;\n")
	if _, err := h.cluster.psql(h.db, "muster", tx.String()); err != nil {
		return refusalResponse(mapSQLError(err))
	}
	return jsonResponse(http.StatusOK, fmt.Sprintf(`{"id":%q,"state":%q,"held":true}`, pl.Subject, curState))
}

func (h *logbookContractHarness) handleNeedsSubtool(worker string, raw []byte) (int, []byte, string) {
	obj, prob := decodeStrictJSON(raw, map[string]bool{"contract": true, "lease": true})
	if prob != nil {
		return refusalResponse(prob)
	}
	leaseStr, prob := decodeRequiredString(obj, "lease")
	if prob != nil {
		return refusalResponse(prob)
	}
	pl, ok := parseLeaseID(leaseStr)
	if !ok {
		return refusalResponse(probBadField)
	}
	if p := h.checkStoreCondition(); p != nil {
		return refusalResponse(p)
	}
	curState, p := h.verifyHeldLease(worker, pl)
	if p != nil {
		return refusalResponse(p)
	}
	if pl.IsProp || pl.Incident || !pausableItemStates[curState] {
		return refusalResponse(probMoveNotAllowed)
	}

	ts := sqlLit(h.now.UTC().Format(time.RFC3339))
	pattern := worker + ".e-needs-subtool." + curState
	var tx strings.Builder
	tx.WriteString("BEGIN;\n")
	fmt.Fprintf(&tx, "DELETE FROM core.queue WHERE queue_id = %d;\n", pl.QueueID)
	fmt.Fprintf(&tx, "UPDATE core.item SET state = 'needs_subtool' WHERE item_id = %s;\n", sqlLit(pl.Subject))
	fmt.Fprintf(&tx, "INSERT INTO core.pause (item_id, worker, pattern, paused_from, paused_at) VALUES (%s, %s, %s, %s, %s);\n",
		sqlLit(pl.Subject), sqlLit(worker), sqlLit(pattern), sqlLit(curState), ts)
	fmt.Fprintf(&tx, "INSERT INTO core.ledger (item_id, actor, from_state, to_state, error_code, note, recorded_at) VALUES (%s, %s, %s, 'needs_subtool', 'E_NEEDS_SUBTOOL', 'paused for missing rule', %s);\n",
		sqlLit(pl.Subject), sqlLit(worker), sqlLit(curState), ts)
	fmt.Fprintf(&tx, "DELETE FROM core.queue WHERE worker = 'bellbuoy' AND item_id = %s;\n", sqlLit(pl.Subject))
	fmt.Fprintf(&tx, "INSERT INTO core.queue (worker, lane, item_id, queued_at) VALUES ('bellbuoy', 'normal', %s, %s);\n",
		sqlLit(pl.Subject), ts)
	tx.WriteString(h.recordLeaseOutcomeTx(pl, leaseStr, worker, "needs_subtool", "", "needs_subtool", "", false, ts) + "\n")
	tx.WriteString("COMMIT;\n")

	if _, err := h.cluster.psql(h.db, "muster", tx.String()); err != nil {
		return refusalResponse(mapSQLError(err))
	}
	h.incidents[pl.Subject] = incidentInfo{Worker: worker, Code: "E_NEEDS_SUBTOOL", State: curState}
	return jsonResponse(http.StatusOK, fmt.Sprintf(`{"id":%q,"state":"needs_subtool"}`, pl.Subject))
}

func (h *logbookContractHarness) handleRelease(raw []byte) (int, []byte, string) {
	obj, prob := decodeStrictJSON(raw, map[string]bool{"contract": true, "id": true})
	if prob != nil {
		return refusalResponse(prob)
	}
	id, prob := decodeRequiredString(obj, "id")
	if prob != nil {
		return refusalResponse(prob)
	}
	if p := h.checkStoreCondition(); p != nil {
		return refusalResponse(p)
	}

	row, err := h.cluster.psql(h.db, "muster", fmt.Sprintf(`SELECT q.queue_id, q.worker, i.state
FROM core.queue q
JOIN core.item i ON i.item_id = q.item_id
WHERE q.item_id = %s AND q.held AND q.worker <> 'bellbuoy'
ORDER BY q.queue_id
LIMIT 1;`, sqlLit(id)))
	if err != nil {
		return refusalResponse(mapSQLError(err))
	}
	if row == "" {
		return refusalResponse(probMoveNotAllowed)
	}
	cols := strings.Split(row, "|")
	queueID, _ := strconv.ParseInt(cols[0], 10, 64)
	worker := cols[1]
	state := cols[2]
	ts := sqlLit(h.now.UTC().Format(time.RFC3339))

	sql := fmt.Sprintf(`BEGIN;
DELETE FROM core.queue WHERE queue_id = %d;
DELETE FROM core.queue WHERE item_id = %s AND worker = 'bellbuoy';
DELETE FROM core.lease_outcome WHERE item_id = %s AND NOT is_incident;
INSERT INTO core.queue (worker, lane, item_id, queued_at) VALUES (%s, 'urgent', %s, %s);
COMMIT;`, queueID, sqlLit(id), sqlLit(id), sqlLit(worker), sqlLit(id), ts)
	if _, err := h.cluster.psql(h.db, "muster", sql); err != nil {
		return refusalResponse(mapSQLError(err))
	}
	delete(h.incidents, id)
	return jsonResponse(http.StatusOK, fmt.Sprintf(`{"id":%q,"state":%q,"next":%q}`, id, state, worker))
}

func (h *logbookContractHarness) handleHealth(raw []byte) (int, []byte, string) {
	obj, prob := decodeStrictJSON(raw, map[string]bool{"contract": true, "reports": true})
	if prob != nil {
		return refusalResponse(prob)
	}
	rawReports, ok := obj["reports"]
	if !ok {
		return refusalResponse(probMissingField)
	}
	var rawList []json.RawMessage
	if err := json.Unmarshal(rawReports, &rawList); err != nil || len(rawList) == 0 {
		return refusalResponse(probBadField)
	}

	type reportItem struct {
		Component string
		State     string
		Code      string
		Digest    string
	}
	seen := map[string]bool{}
	reports := make([]reportItem, 0, len(rawList))
	digestRe := regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

	for _, entry := range rawList {
		dec := json.NewDecoder(bytes.NewReader(entry))
		var m map[string]json.RawMessage
		if err := dec.Decode(&m); err != nil || m == nil {
			return refusalResponse(probBadField)
		}
		for k := range m {
			if k != "component" && k != "state" && k != "code" && k != "digest" {
				return refusalResponse(probUnknownField)
			}
		}
		comp, p := decodeRequiredString(m, "component")
		if p != nil {
			return refusalResponse(p)
		}
		if _, ok := knownComponents[comp]; !ok {
			return refusalResponse(probBadField)
		}
		st, p := decodeRequiredString(m, "state")
		if p != nil {
			return refusalResponse(p)
		}
		switch st {
		case "healthy", "idle", "degraded", "paused":
		default:
			// Verify Logbook's check_component_health also refuses this state with E_NEEDS_SUBTOOL.
			_, err := h.cluster.psql(h.db, "muster", fmt.Sprintf(
				"INSERT INTO core.component_health (component, state) VALUES (%s, %s);",
				sqlLit(comp), sqlLit(st),
			))
			if err == nil || !strings.Contains(err.Error(), "E_NEEDS_SUBTOOL:") {
				return refusalResponse(probUnexpected)
			}
			return refusalResponse(probUnknownHealth)
		}
		code, p := decodeOptionalString(m, "code", false)
		if p != nil {
			return refusalResponse(p)
		}
		if code != "" && code != "E_TIMEOUT" && code != "E_PARSE" && code != "E_NEEDS_SUBTOOL" {
			return refusalResponse(probBadField)
		}
		digest, p := decodeOptionalString(m, "digest", false)
		if p != nil {
			return refusalResponse(p)
		}
		if digest != "" && !digestRe.MatchString(digest) {
			return refusalResponse(probBadField)
		}
		if seen[comp] {
			return refusalResponse(probDuplicate)
		}
		seen[comp] = true
		reports = append(reports, reportItem{Component: comp, State: st, Code: code, Digest: digest})
	}

	if p := h.checkStoreCondition(); p != nil {
		return refusalResponse(p)
	}

	ts := sqlLit(h.now.UTC().Format(time.RFC3339))
	replayedTotal := 0
	liveTotal := 0

	for _, r := range reports {
		prevDigest, err := h.cluster.psql(h.db, "muster", fmt.Sprintf(
			"SELECT coalesce(digest, '') FROM core.component_health WHERE component = %s;",
			sqlLit(r.Component),
		))
		if err != nil {
			return refusalResponse(mapSQLError(err))
		}
		digestChanged := r.Digest != "" && prevDigest != "" && prevDigest != r.Digest

		var tx strings.Builder
		tx.WriteString("BEGIN;\n")
		fmt.Fprintf(&tx, `INSERT INTO core.component_health (component, state, error_code, digest, reported_at)
VALUES (%s, %s, %s, %s, %s)
ON CONFLICT (component) DO UPDATE
SET state = EXCLUDED.state,
    error_code = EXCLUDED.error_code,
    digest = COALESCE(EXCLUDED.digest, core.component_health.digest),
    reported_at = EXCLUDED.reported_at;`+"\n",
			sqlLit(r.Component), sqlLit(r.State), sqlNullableLit(r.Code), sqlNullableLit(r.Digest), ts,
		)
		tx.WriteString("COMMIT;\n")
		if _, err := h.cluster.psql(h.db, "muster", tx.String()); err != nil {
			return refusalResponse(mapSQLError(err))
		}

		if !digestChanged {
			continue
		}

		// Replay any open pauses for this worker.
		pausedRows, err := h.cluster.psql(h.db, "muster", fmt.Sprintf(`SELECT pause_id, item_id, paused_from
FROM core.pause
WHERE worker = %s AND replayed_at IS NULL
ORDER BY pause_id;`, sqlLit(r.Component)))
		if err != nil {
			return refusalResponse(mapSQLError(err))
		}
		if pausedRows != "" {
			for _, line := range strings.Split(pausedRows, "\n") {
				parts := strings.Split(line, "|")
				pauseID, _ := strconv.ParseInt(parts[0], 10, 64)
				itemID := parts[1]
				pausedFrom := parts[2]
				replaySQL := fmt.Sprintf(`BEGIN;
UPDATE core.pause SET replayed_at = %s WHERE pause_id = %d;
UPDATE core.item SET state = %s WHERE item_id = %s;
INSERT INTO core.ledger (item_id, actor, from_state, to_state, note, recorded_at)
VALUES (%s, 'muster', 'needs_subtool', %s, 'replayed on new digest', %s);
DELETE FROM core.queue WHERE item_id = %s AND worker = 'bellbuoy';
INSERT INTO core.queue (worker, lane, item_id, queued_at)
VALUES (%s, 'urgent', %s, %s);
COMMIT;`, ts, pauseID, sqlLit(pausedFrom), sqlLit(itemID), sqlLit(itemID), sqlLit(pausedFrom), ts, sqlLit(itemID), sqlLit(r.Component), sqlLit(itemID), ts)
				if _, err := h.cluster.psql(h.db, "muster", replaySQL); err != nil {
					return refusalResponse(mapSQLError(err))
				}
				delete(h.incidents, itemID)
				replayedTotal++
			}
		}

		// Mark any building edit proposals in this component's repository as live.
		repo := knownComponents[r.Component]
		propRows, err := h.cluster.psql(h.db, "muster", fmt.Sprintf(`SELECT proposal_id
FROM core.edit_proposal
WHERE owner_repo = %s AND status = 'building'
ORDER BY proposal_id;`, sqlLit(repo)))
		if err != nil {
			return refusalResponse(mapSQLError(err))
		}
		if propRows != "" {
			for _, line := range strings.Split(propRows, "\n") {
				propID, _ := strconv.ParseInt(strings.TrimSpace(line), 10, 64)
				liveSQL := fmt.Sprintf(`BEGIN;
UPDATE core.edit_proposal SET status = 'live', decided_at = COALESCE(decided_at, %s) WHERE proposal_id = %d;
INSERT INTO core.ledger (proposal_id, actor, from_state, to_state, recorded_at)
VALUES (%d, 'shipkeeper', 'building', 'live', %s);
COMMIT;`, ts, propID, propID, ts)
				if _, err := h.cluster.psql(h.db, "muster", liveSQL); err != nil {
					return refusalResponse(mapSQLError(err))
				}
				liveTotal++
			}
		}
	}

	body := fmt.Sprintf(`{"received":%d,"replayed":%d,"live":%d}`, len(reports), replayedTotal, liveTotal)
	return jsonResponse(http.StatusOK, body)
}

func (h *logbookContractHarness) handleFeed() (int, []byte, string) {
	if p := h.checkStoreCondition(); p != nil {
		return refusalResponse(p)
	}
	nowStr := h.now.UTC().Format(time.RFC3339)
	depthsRow, err := h.cluster.psql(h.db, "muster", fmt.Sprintf(`SELECT
  (SELECT count(*) FROM core.queue WHERE NOT held AND queued_at <= %s AND lane = 'urgent'),
  (SELECT count(*) FROM core.queue WHERE NOT held AND queued_at <= %s AND lane = 'normal'),
  (SELECT count(*) FROM core.queue WHERE NOT held AND queued_at <= %s AND lane = 'backfill'),
  (SELECT count(*) FROM core.item WHERE state = 'needs_subtool');`,
		sqlLit(nowStr), sqlLit(nowStr), sqlLit(nowStr),
	))
	if err != nil {
		return refusalResponse(mapSQLError(err))
	}
	dCols := strings.Split(depthsRow, "|")

	// Read component health from pub.component_health as pub_ro to prove Conn's public view matches Contract v1.
	healthRows, err := h.cluster.psql(h.db, "pub_ro",
		"SELECT component || '|' || state || '|' || coalesce(error_code, '') FROM pub.component_health ORDER BY component;")
	if err != nil {
		return refusalResponse(mapSQLError(err))
	}

	var stream strings.Builder
	eventID := 1
	fmt.Fprintf(&stream, "id: %d\nevent: depths\ndata: {\"at\":%q,\"urgent\":%s,\"normal\":%s,\"backfill\":%s,\"needs_subtool\":%s}\n\n",
		eventID, nowStr, dCols[0], dCols[1], dCols[2], dCols[3])
	if healthRows != "" {
		for _, line := range strings.Split(healthRows, "\n") {
			eventID++
			parts := strings.SplitN(line, "|", 3)
			if parts[2] != "" {
				fmt.Fprintf(&stream, "id: %d\nevent: health\ndata: {\"at\":%q,\"component\":%q,\"state\":%q,\"code\":%q}\n\n",
					eventID, nowStr, parts[0], parts[1], parts[2])
			} else {
				fmt.Fprintf(&stream, "id: %d\nevent: health\ndata: {\"at\":%q,\"component\":%q,\"state\":%q}\n\n",
					eventID, nowStr, parts[0], parts[1])
			}
		}
	}
	return http.StatusOK, nil, stream.String()
}

func (h *logbookContractHarness) verifyDatabaseInvariants(t *testing.T) {
	t.Helper()
	// 1. Every integrity check in core.integrity_check() must pass with zero failures.
	bad, err := h.cluster.psql(h.db, "", "SELECT check_name || ': ' || failures FROM core.integrity_check() WHERE failures > 0;")
	if err != nil {
		t.Fatalf("core.integrity_check() failed: %v", err)
	}
	if bad != "" {
		t.Errorf("core.integrity_check() reported failures:\n%s", bad)
	}

	// 2. pub_ro can read all 11 public views without error.
	pubSQL := `SELECT
  (SELECT count(*) FROM pub.item) +
  (SELECT count(*) FROM pub.item_history) +
  (SELECT count(*) FROM pub.evaluation) +
  (SELECT count(*) FROM pub.evaluation_gate) +
  (SELECT count(*) FROM pub.evaluation_factor) +
  (SELECT count(*) FROM pub.decision) +
  (SELECT count(*) FROM pub.queue_depth) +
  (SELECT count(*) FROM pub.pause) +
  (SELECT count(*) FROM pub.edit_proposal) +
  (SELECT count(*) FROM pub.restore_drill) +
  (SELECT count(*) FROM pub.component_health);`
	if _, err := h.cluster.psql(h.db, "pub_ro", pubSQL); err != nil {
		t.Fatalf("pub_ro could not read public views: %v", err)
	}

	// 3. No private working value (reasons, file paths, unapproved proposal text, worker results,
	// lease identifiers, image digests, visitor HMAC keys or raw visitor IP) appears in pub.*.
	leakSQL := `WITH published AS (
  SELECT to_jsonb(v)::text AS line FROM pub.item v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.item_history v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.evaluation v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.evaluation_gate v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.evaluation_factor v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.decision v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.queue_depth v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.pause v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.edit_proposal v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.restore_drill v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.component_health v
),
secrets AS (
  SELECT source AS val FROM core.item WHERE source IS NOT NULL
  UNION ALL SELECT reason FROM core.edit_proposal WHERE reason IS NOT NULL
  UNION ALL SELECT file_path FROM core.edit_proposal WHERE file_path IS NOT NULL
  UNION ALL SELECT payload FROM core.edit_proposal WHERE status NOT IN ('approved', 'building', 'live')
  UNION ALL SELECT payload::text FROM core.result
  UNION ALL SELECT lease FROM core.lease_outcome
  UNION ALL SELECT digest FROM core.component_health WHERE digest IS NOT NULL
  UNION ALL SELECT visitor_key FROM core.submission_count
  UNION ALL SELECT '203.0.113.7'
)
SELECT count(*) FROM published p JOIN secrets s ON position(s.val IN p.line) > 0;`
	leaks, err := h.cluster.psql(h.db, "", leakSQL)
	if err != nil {
		t.Fatalf("public leak check failed: %v", err)
	}
	if strings.TrimSpace(leaks) != "0" {
		t.Errorf("public views leaked %s private values", leaks)
	}
}

func TestContractExamples(t *testing.T) {
	paths, err := filepath.Glob(filepath.Join(contractDir, "*.json"))
	if err != nil || len(paths) == 0 {
		t.Fatalf("no saved Contract v1 examples found in %s: %v", contractDir, err)
	}
	sort.Strings(paths)
	if len(paths) != 52 {
		t.Fatalf("found %d Contract v1 examples, want 52", len(paths))
	}

	cluster := startPGCluster(t)
	seenPaths := map[string]bool{}
	seenProblems := map[*problem]bool{}

	for _, path := range paths {
		name := strings.TrimSuffix(filepath.Base(path), ".json")
		t.Run(name, func(t *testing.T) {
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var ex contractExample
			dec := json.NewDecoder(bytes.NewReader(raw))
			dec.DisallowUnknownFields()
			if err := dec.Decode(&ex); err != nil {
				t.Fatalf("decode %s: %v", path, err)
			}
			if ex.About == "" {
				t.Fatal("example is missing about")
			}

			var seed []seedItem
			if ex.Given != nil {
				seed = ex.Given.Items
			}
			h := newHarness(t, cluster, seed)

			if g := ex.Given; g != nil {
				for i, call := range g.Calls {
					code, body, _ := h.dispatch(t, call)
					if code < 200 || code > 299 {
						t.Fatalf("given call %d (%s %s) failed: %d %s", i+1, call.Method, call.Path, code, body)
					}
				}
				if g.Wait != "" {
					d, err := time.ParseDuration(g.Wait)
					if err != nil {
						t.Fatalf("parse wait %q: %v", g.Wait, err)
					}
					h.now = h.now.Add(d)
				}
				h.arrange(t, g.Condition)
			}

			seenPaths[ex.Request.Path] = true
			status, body, stream := h.dispatch(t, ex.Request)

			if ex.Expect.Stream != nil {
				if status != ex.Expect.Status || stream != *ex.Expect.Stream {
					t.Errorf("stream mismatch:\ngot  %d:\n%s\nwant %d:\n%s", status, stream, ex.Expect.Status, *ex.Expect.Stream)
				}
			} else {
				var want []byte
				if ex.Expect.Body != nil {
					var buf bytes.Buffer
					if err := json.Compact(&buf, ex.Expect.Body); err != nil {
						t.Fatalf("compact expect.body: %v", err)
					}
					want = append(buf.Bytes(), '\n')
				}
				if status != ex.Expect.Status || !bytes.Equal(body, want) {
					t.Errorf("response mismatch:\ngot:  %d %s\nwant: %d %s", status, body, ex.Expect.Status, want)
				}
			}

			if status >= 400 {
				var r struct {
					Error  string `json:"error"`
					Cause  string `json:"cause"`
					Reason string `json:"reason"`
				}
				if err := json.Unmarshal(body, &r); err != nil {
					t.Fatalf("unmarshal refusal %q: %v", body, err)
				}
				for _, p := range allContractProblems() {
					if p.Status == status && p.Code == r.Error && p.Cause == r.Cause && p.Reason == r.Reason {
						seenProblems[p] = true
					}
				}
			}

			h.verifyDatabaseInvariants(t)
		})
	}

	for _, p := range allContractPaths() {
		if !seenPaths[p] {
			t.Errorf("no saved example exercised %s", p)
		}
	}
	for _, pr := range allContractProblems() {
		if !seenProblems[pr] {
			t.Errorf("no saved example exercised refusal %v", pr)
		}
	}
}
