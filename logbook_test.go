package logbook_test

import (
	"bytes"
	"encoding/json"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

func TestStandardLibraryOnly(t *testing.T) {
	modBytes, err := os.ReadFile("go.mod")
	if err != nil {
		t.Fatalf("read go.mod: %v", err)
	}
	var sawModule bool
	for _, raw := range strings.Split(string(modBytes), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "//") {
			continue
		}
		switch {
		case line == "module github.com/ClearedStack/logbook":
			sawModule = true
		case strings.HasPrefix(line, "go "):
		default:
			t.Errorf("unexpected directive in go.mod: %q", line)
		}
	}
	if !sawModule {
		t.Error("go.mod does not declare module github.com/ClearedStack/logbook")
	}
	if _, err := os.Stat("go.sum"); err == nil {
		t.Error("go.sum must not exist when only the standard library is used")
	}

	fset := token.NewFileSet()
	err = filepath.WalkDir(".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") {
			return nil
		}
		file, err := parser.ParseFile(fset, path, nil, parser.ImportsOnly)
		if err != nil {
			t.Fatalf("parse %s: %v", path, err)
		}
		for _, imp := range file.Imports {
			pkg := strings.Trim(imp.Path.Value, `"`)
			first, _, _ := strings.Cut(pkg, "/")
			if strings.Contains(first, ".") {
				t.Errorf("%s imports external package %q", path, pkg)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestNoEmDashes(t *testing.T) {
	const emDash = "\u2014"
	err := filepath.WalkDir(".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if strings.Contains(string(data), emDash) {
			t.Errorf("%s contains an em dash", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestNoSecretsInRepo(t *testing.T) {
	forbidden := []*regexp.Regexp{
		regexp.MustCompile(`(?m)^kind:\s*Secret\b`),
		regexp.MustCompile(`BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY`),
		regexp.MustCompile(`\b(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b`),
	}
	err := filepath.WalkDir(".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(path, "_test.go") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		text := string(data)
		for _, re := range forbidden {
			if re.MatchString(text) {
				t.Errorf("%s matches forbidden secret pattern %s", path, re)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	// Every password environment variable in deploy/ must come from secretKeyRef.
	passwordLiteral := regexp.MustCompile(`(?m)^\s*-\s*name:\s*[A-Z_]*PASSWORD\s*\n\s*value:`)
	manifestPaths, err := filepath.Glob("deploy/*.yaml")
	if err != nil || len(manifestPaths) == 0 {
		t.Fatalf("glob deploy/*.yaml: %v", err)
	}
	for _, p := range manifestPaths {
		data, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if passwordLiteral.Match(data) {
			t.Errorf("%s sets a literal PASSWORD value instead of secretKeyRef", p)
		}
	}
}

func TestComponentMetadata(t *testing.T) {
	raw, err := os.ReadFile("component.json")
	if err != nil {
		t.Fatalf("read component.json: %v", err)
	}
	var comp struct {
		Slug           string   `json:"slug"`
		Name           string   `json:"name"`
		Formerly       string   `json:"formerly"`
		Kind           string   `json:"kind"`
		Namespace      string   `json:"namespace"`
		Responsibility string   `json:"responsibility"`
		Interfaces     []string `json:"interfaces"`
		Repository     string   `json:"repository"`
		Image          string   `json:"image"`
		DependsOn      []string `json:"dependsOn"`
		Memory         string   `json:"memory"`
		Version        string   `json:"version"`
		SubTools       []string `json:"subTools"`
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&comp); err != nil {
		t.Fatalf("decode component.json: %v", err)
	}
	if comp.Slug != "logbook" {
		t.Errorf("component.json slug = %q, want %q", comp.Slug, "logbook")
	}
	if comp.Kind != "control-plane" {
		t.Errorf("component.json kind = %q, want %q", comp.Kind, "control-plane")
	}
	if comp.Namespace != "clearedstack" {
		t.Errorf("component.json namespace = %q, want %q", comp.Namespace, "clearedstack")
	}
	if comp.Repository != "logbook" {
		t.Errorf("component.json repository = %q, want %q", comp.Repository, "logbook")
	}
	if comp.Memory != "256 MiB" {
		t.Errorf("component.json memory = %q, want %q", comp.Memory, "256 MiB")
	}
	if comp.Version != "17" {
		t.Errorf("component.json version = %q, want %q", comp.Version, "17")
	}

	lic, err := os.ReadFile("LICENSE")
	if err != nil {
		t.Fatalf("read LICENSE: %v", err)
	}
	if !strings.Contains(string(lic), "MIT License") {
		t.Error("LICENSE is not MIT")
	}
}

func TestDeployManifests(t *testing.T) {
	kustomBytes, err := os.ReadFile("kustomization.yaml")
	if err != nil {
		t.Fatalf("read kustomization.yaml: %v", err)
	}
	kustom := string(kustomBytes)

	deployFiles, err := filepath.Glob("deploy/*.yaml")
	if err != nil || len(deployFiles) == 0 {
		t.Fatalf("glob deploy/*.yaml: %v", err)
	}
	sort.Strings(deployFiles)
	for _, f := range deployFiles {
		if !strings.Contains(kustom, "- "+f) {
			t.Errorf("kustomization.yaml does not list %s", f)
		}
	}

	migrations, err := filepath.Glob("migrations/*.sql")
	if err != nil || len(migrations) == 0 {
		t.Fatalf("glob migrations/*.sql: %v", err)
	}
	sort.Strings(migrations)
	for _, m := range migrations {
		if !strings.Contains(kustom, "- "+m) {
			t.Errorf("kustomization.yaml does not list %s", m)
		}
	}
	for _, script := range []string{"migrate.sh", "dump.sh", "restore-drill.sh"} {
		if !strings.Contains(kustom, "- "+script) {
			t.Errorf("kustomization.yaml does not include %s", script)
		}
	}

	// Namespace and PriorityClass.
	ns := mustRead(t, "deploy/namespace.yaml")
	requireContains(t, "deploy/namespace.yaml", ns, "kind: Namespace", "name: clearedstack")

	pc := mustRead(t, "deploy/priorityclass.yaml")
	requireContains(t, "deploy/priorityclass.yaml", pc,
		"kind: PriorityClass",
		"name: clearedstack-high",
		"globalDefault: false",
	)

	// Every container image across deploy/*.yaml must be pinned by sha256 digest.
	imageLine := regexp.MustCompile(`(?m)^\s*image:\s*(\S+)\s*$`)
	pinnedDigest := regexp.MustCompile(`^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$`)
	var imageCount int
	for _, f := range deployFiles {
		text := mustRead(t, f)
		for _, m := range imageLine.FindAllStringSubmatch(text, -1) {
			imageCount++
			if !pinnedDigest.MatchString(m[1]) {
				t.Errorf("%s has unpinned image %q", f, m[1])
			}
		}
	}
	if imageCount < 2 {
		t.Errorf("found %d container images in deploy/, want at least 2", imageCount)
	}

	// Workload security, node affinity and resource checks on both logbook and logbook-migrate.
	for _, f := range []string{"deploy/logbook.yaml", "deploy/migrate-job.yaml"} {
		text := mustRead(t, f)
		requireContains(t, f, text,
			"namespace: clearedstack",
			"automountServiceAccountToken: false",
			"key: kubernetes.io/arch",
			"operator: In",
			`values: ["arm64"]`,
			"key: kubernetes.io/hostname",
			"operator: NotIn",
			`values: ["cm3588-plus"]`,
			"runAsNonRoot: true",
			"runAsUser: 999",
			"runAsGroup: 999",
			"seccompProfile:",
			"type: RuntimeDefault",
			"privileged: false",
			"allowPrivilegeEscalation: false",
			"readOnlyRootFilesystem: true",
			`drop: ["ALL"]`,
		)
		if strings.Contains(text, "add:") {
			t.Errorf("%s adds Linux capabilities", f)
		}
		checkSmallResources(t, f, text)
	}

	// StatefulSet-specific checks.
	stateful := mustRead(t, "deploy/logbook.yaml")
	requireContains(t, "deploy/logbook.yaml", stateful,
		"kind: StatefulSet",
		"priorityClassName: clearedstack-high",
		"shared_buffers=32MB",
		"work_mem=2MB",
		"max_connections=25",
		"storageClassName: longhorn",
		"storage: 1Gi",
		"mountPath: /logbook/bin",
		"readOnly: true",
		"name: logbook-migrate",
	)

	// NetworkPolicy checks: default-deny, logbook-ingress (only migrate, muster, conn on TCP 5432, egress []),
	// and logbook-migrate-egress (ingress [], egress only to logbook:5432 and kube-system DNS).
	netpol := mustRead(t, "deploy/networkpolicy.yaml")
	docs := strings.Split(netpol, "\n---\n")
	if len(docs) != 3 {
		t.Fatalf("deploy/networkpolicy.yaml has %d documents, want 3", len(docs))
	}

	requireContains(t, "networkpolicy[default-deny]", docs[0],
		"name: default-deny",
		"namespace: clearedstack",
		"podSelector: {}",
		"- Ingress",
		"- Egress",
	)
	if strings.Contains(docs[0], "\n  ingress:") || strings.Contains(docs[0], "\n  egress:") {
		t.Error("default-deny must not contain ingress or egress allow rules")
	}

	requireContains(t, "networkpolicy[logbook-ingress]", docs[1],
		"name: logbook-ingress",
		"namespace: clearedstack",
		"app.kubernetes.io/name: logbook",
		"- Ingress",
		"- Egress",
		"- logbook-migrate",
		"- muster",
		"- conn",
		"protocol: TCP",
		"port: 5432",
		"egress: []",
	)
	ingressBody := stripYAMLComments(docs[1])
	if strings.Contains(ingressBody, "namespaceSelector") || strings.Contains(ingressBody, "cs-workers") {
		t.Error("logbook-ingress must not open Logbook to namespaces outside clearedstack")
	}

	requireContains(t, "networkpolicy[logbook-migrate-egress]", docs[2],
		"name: logbook-migrate-egress",
		"namespace: clearedstack",
		"- Ingress",
		"- Egress",
		"ingress: []",
		"app.kubernetes.io/name: logbook",
		"port: 5432",
		"kubernetes.io/metadata.name: kube-system",
		"port: 53",
	)
}

func checkSmallResources(t *testing.T, file, text string) {
	t.Helper()
	cpuRe := regexp.MustCompile(`(?m)^\s*cpu:\s*([0-9]+)m\s*$`)
	memRe := regexp.MustCompile(`(?m)^\s*memory:\s*([0-9]+)Mi\s*$`)

	cpus := cpuRe.FindAllStringSubmatch(text, -1)
	if len(cpus) == 0 {
		t.Errorf("%s does not set a millicore cpu request", file)
	}
	for _, m := range cpus {
		v, _ := strconv.Atoi(m[1])
		if v <= 0 || v > 100 {
			t.Errorf("%s cpu = %dm, want 1..100m", file, v)
		}
	}

	mems := memRe.FindAllStringSubmatch(text, -1)
	if len(mems) < 2 {
		t.Errorf("%s should set both memory request and memory limit in Mi", file)
	}
	for _, m := range mems {
		v, _ := strconv.Atoi(m[1])
		if v <= 0 || v > 256 {
			t.Errorf("%s memory = %dMi, want 1..256Mi", file, v)
		}
	}
}

func mustRead(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}

func requireContains(t *testing.T, label, text string, needles ...string) {
	t.Helper()
	for _, n := range needles {
		if !strings.Contains(text, n) {
			t.Errorf("%s is missing %q", label, n)
		}
	}
}

func stripYAMLComments(text string) string {
	var out strings.Builder
	for _, line := range strings.Split(text, "\n") {
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		out.WriteString(line)
		out.WriteByte('\n')
	}
	return out.String()
}

// postgresEnv returns an environment with PostgreSQL 17 client and server
// tools on PATH, or skips the test when PostgreSQL 17 is not installed.
func postgresEnv(t *testing.T) []string {
	t.Helper()
	candidates := []string{""}
	if _, err := os.Stat("/usr/lib/postgresql/17/bin/initdb"); err == nil {
		candidates = append(candidates, "/usr/lib/postgresql/17/bin")
	}
	baseEnv := os.Environ()
	for _, dir := range candidates {
		env := append([]string(nil), baseEnv...)
		initdbBin := "initdb"
		if dir != "" {
			initdbBin = filepath.Join(dir, "initdb")
			env = withPathPrefix(env, dir)
		}
		cmd := exec.Command(initdbBin, "--version")
		cmd.Env = env
		out, err := cmd.CombinedOutput()
		if err != nil {
			continue
		}
		if strings.Contains(string(out), " 17.") || strings.HasSuffix(strings.TrimSpace(string(out)), " 17") {
			return env
		}
	}
	if os.Getenv("LOGBOOK_REQUIRE_PG17") == "1" {
		t.Fatal("PostgreSQL 17 is required (LOGBOOK_REQUIRE_PG17=1) and is not on PATH")
	}
	t.Skip("PostgreSQL 17 is not on PATH; skipping live database test")
	return nil
}

func withPathPrefix(env []string, dir string) []string {
	out := make([]string, 0, len(env)+1)
	replaced := false
	for _, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			out = append(out, "PATH="+dir+string(os.PathListSeparator)+strings.TrimPrefix(kv, "PATH="))
			replaced = true
		} else {
			out = append(out, kv)
		}
	}
	if !replaced {
		out = append(out, "PATH="+dir)
	}
	return out
}

func TestSavedSQLSuite(t *testing.T) {
	env := postgresEnv(t)
	cmd := exec.Command("sh", "tests/run.sh")
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("sh tests/run.sh failed: %v\n%s", err, out)
	}
	sqlCases, err := filepath.Glob("tests/cases/*.sql")
	if err != nil {
		t.Fatal(err)
	}
	shCases, err := filepath.Glob("tests/cases/*.sh")
	if err != nil {
		t.Fatal(err)
	}
	okLines := 0
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if strings.HasPrefix(line, "ok ") {
			okLines++
		}
	}
	want := len(sqlCases) + len(shCases)
	if okLines != want {
		t.Fatalf("sh tests/run.sh reported %d ok lines, want %d:\n%s", okLines, want, out)
	}
}

func TestBackupAndRestoreDrill(t *testing.T) {
	cluster := startPGCluster(t)
	db := cluster.newDatabase(t)

	seedSQL := `
INSERT INTO core.item (state, title, address, source)
VALUES ('recorded', 'Sample FAR Clause Calculator', 'https://sam.gov/opp/sample-1', 'sam-gov');
INSERT INTO core.ledger (item_id, from_state, to_state, actor, note)
VALUES ('PA-0001', NULL, 'recorded', 'muster', 'Recorded from intake.');
INSERT INTO core.result (item_id, worker, payload)
VALUES ('PA-0001', 'sextant', '{"clauses":["52.204-21"]}'::jsonb);
INSERT INTO core.component_health (component, state, digest)
VALUES ('logbook', 'healthy', 'sha256:846a7ddaa67a4b354ae1d21087b683901aa6113a4ed626d3787cfbf6c85e3e07');
`
	if _, err := cluster.psql(db, "muster", seedSQL); err != nil {
		t.Fatalf("seed database: %v", err)
	}

	tmp := t.TempDir()
	plainDump := filepath.Join(tmp, "logbook.dump.sql")
	dbEnv := append(append([]string(nil), cluster.env...), "PGDATABASE="+db, "TMPDIR="+tmp)

	dumpCmd := exec.Command("sh", "dump.sh", "-o", plainDump)
	dumpCmd.Env = dbEnv
	if out, err := dumpCmd.CombinedOutput(); err != nil {
		t.Fatalf("dump.sh failed: %v\n%s", err, out)
	}

	drillCmd := exec.Command("sh", "restore-drill.sh", "-f", plainDump)
	drillCmd.Env = dbEnv
	drillOut, err := drillCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("restore-drill.sh failed: %v\n%s", err, drillOut)
	}
	requireContains(t, "restore-drill.sh plain output", string(drillOut),
		"restore ok\n",
		"integrity ok: 19 checks, 0 failures\n",
		"privileges ok\n",
	)

	ageBin, errAge := exec.LookPath("age")
	keygenBin, errKeygen := exec.LookPath("age-keygen")
	if errAge != nil || errKeygen != nil {
		if os.Getenv("LOGBOOK_REQUIRE_AGE") == "1" {
			t.Fatalf("age and age-keygen are required (LOGBOOK_REQUIRE_AGE=1): age=%v age-keygen=%v", errAge, errKeygen)
		}
		return
	}
	_ = ageBin

	goodKey := filepath.Join(tmp, "good-age-key.txt")
	keygenOut, err := exec.Command(keygenBin, "-o", goodKey).CombinedOutput()
	if err != nil {
		t.Fatalf("age-keygen good key: %v\n%s", err, keygenOut)
	}
	keyData, err := os.ReadFile(goodKey)
	if err != nil {
		t.Fatal(err)
	}
	var recipient string
	for _, line := range strings.Split(string(keyData), "\n") {
		if after, ok := strings.CutPrefix(strings.TrimSpace(line), "# public key: "); ok {
			recipient = strings.TrimSpace(after)
			break
		}
	}
	if recipient == "" {
		t.Fatalf("could not extract public key from age-keygen output")
	}

	encDump := filepath.Join(tmp, "logbook.dump.sql.age")
	encCmd := exec.Command("sh", "dump.sh", "-r", recipient, "-o", encDump)
	encCmd.Env = dbEnv
	if out, err := encCmd.CombinedOutput(); err != nil {
		t.Fatalf("encrypted dump.sh failed: %v\n%s", err, out)
	}
	encBytes, err := os.ReadFile(encDump)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encBytes, []byte("CREATE SCHEMA")) || bytes.Contains(encBytes, []byte("Sample FAR Clause")) {
		t.Fatal("encrypted dump leaked plaintext SQL")
	}

	encDrill := exec.Command("sh", "restore-drill.sh", "-f", encDump, "-i", goodKey)
	encDrill.Env = dbEnv
	encDrillOut, err := encDrill.CombinedOutput()
	if err != nil {
		t.Fatalf("encrypted restore-drill.sh failed: %v\n%s", err, encDrillOut)
	}
	requireContains(t, "restore-drill.sh encrypted output", string(encDrillOut),
		"decrypt ok\n",
		"restore ok\n",
		"integrity ok: 19 checks, 0 failures\n",
		"privileges ok\n",
	)

	wrongKey := filepath.Join(tmp, "wrong-age-key.txt")
	if out, err := exec.Command(keygenBin, "-o", wrongKey).CombinedOutput(); err != nil {
		t.Fatalf("age-keygen wrong key: %v\n%s", err, out)
	}
	wrongDrill := exec.Command("sh", "restore-drill.sh", "-f", encDump, "-i", wrongKey)
	wrongDrill.Env = dbEnv
	wrongOut, err := wrongDrill.CombinedOutput()
	if err == nil {
		t.Fatalf("expected restore-drill.sh to fail with wrong age key, got:\n%s", wrongOut)
	}
	requireContains(t, "restore-drill.sh wrong key output", string(wrongOut), "E_PARSE:")
}
