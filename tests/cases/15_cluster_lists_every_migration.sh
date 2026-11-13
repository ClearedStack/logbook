# kustomization.yaml names each migration it hands to the cluster, one by one.
# A migration that is in migrations/ and not named there would never be applied
# in the cluster, and a name with no file would stop every sync.
cd "$LOGBOOK_ROOT"
for file in migrations/*.sql; do
    grep -q "^      - $file\$" kustomization.yaml ||
        printf 'kustomization.yaml does not list %s\n' "$file"
done
sed -n 's/^      - \(migrations\/.*\)$/\1/p' kustomization.yaml | while read -r file; do
    [ -f "$file" ] || printf 'kustomization.yaml lists %s, which is not there\n' "$file"
done
printf 'checked\n'
