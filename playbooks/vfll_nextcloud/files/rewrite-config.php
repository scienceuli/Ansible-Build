<?php
// Rewrite a copied Nextcloud config for the container stack.
// Usage: php rewrite-config.php <config dir> <changes.json>
// changes.json: {"set": {"key": value, ...}, "unset": ["key", ...],
//                "rename": {"old key": "new key", ...}}
//
// config.php: "set" replaces whole top-level keys (arrays included), "unset"
// removes keys, "rename" moves a deprecated key's value (from whichever file
// wins) to the new key unless that is already set. Everything else -
// instanceid, passwordsalt, secret, mail settings - stays.
// Other *.config.php files (e.g. tweaks.config.php) are read after config.php
// and override it, so every key from "set"/"unset"/"rename" is removed from
// them - otherwise e.g. an old redis unix socket there would win.
// Files are only written when something changes; changes are printed.

[$script, $dir, $changesFile] = $argv;
$changes = json_decode(file_get_contents($changesFile), true, 512, JSON_THROW_ON_ERROR);
$renames = $changes['rename'] ?? [];
$keys = array_merge(array_keys($changes['set'] ?? []), $changes['unset'] ?? [],
    array_keys($renames), array_values($renames));
$extras = glob("$dir/*.config.php");

function load(string $file): array {
    $CONFIG = [];
    require $file;
    return $CONFIG;
}

function save(string $file, array $config): void {
    $tmp = $file . '.tmp';
    file_put_contents($tmp, "<?php\n\$CONFIG = " . var_export($config, true) . ";\n");
    if (!is_array(load($tmp))) {
        fwrite(STDERR, "rewritten $file invalid\n");
        exit(1);
    }
    rename($tmp, $file);
}

$main = "$dir/config.php";
$config = load($main);
$original = $config;
foreach ($renames as $old => $new) {
    // same order as Nextcloud: the last file setting the key wins
    $value = null;
    foreach (array_merge([$main], $extras) as $file) {
        $fileConfig = $file === $main ? $original : load($file);
        if (array_key_exists($old, $fileConfig)) {
            $value = $fileConfig[$old];
        }
    }
    if ($value !== null && !array_key_exists($new, $config)) {
        $config[$new] = $value;
    }
    unset($config[$old]);
}
foreach ($changes['unset'] ?? [] as $key) {
    unset($config[$key]);
}
foreach ($changes['set'] ?? [] as $key => $value) {
    $config[$key] = $value;
}
if (empty($config['instanceid'])) {
    fwrite(STDERR, "config.php without instanceid - wrong file?\n");
    exit(1);
}
if ($config !== $original) {
    save($main, $config);
    echo "config.php: updated\n";
}

foreach ($extras as $extra) {
    $extraConfig = load($extra);
    $removed = array_intersect($keys, array_keys($extraConfig));
    if ($removed) {
        save($extra, array_diff_key($extraConfig, array_flip($removed)));
        echo basename($extra) . ": removed " . implode(', ', $removed) . "\n";
    }
}
