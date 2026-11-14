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
	if !strings.Contains(kustom, "- migrate.sh") {
		t.Error("kustomization.yaml does not include migrate.sh")
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
	cases, err := filepath.Glob("tests/cases/*.sql")
	if err != nil {
		t.Fatal(err)
	}
	okLines := 0
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if strings.HasPrefix(line, "ok ") {
			okLines++
		}
	}
	// 15 SQL cases in tests/cases/ plus 3 runner checks (13_migrate, 14_dump_and_restore, 15_cluster_lists_every_migration).
	want := len(cases) + 3
	if okLines != want {
		t.Fatalf("sh tests/run.sh reported %d ok lines, want %d:\n%s", okLines, want, out)
	}
}
