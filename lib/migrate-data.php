<?php
/**
 * Pterodactyl → Skyport data migration helper.
 * Run from the Skyport panel directory:
 *   php lib/migrate-data.php <ptero_db_host> <ptero_db_port> <ptero_db_name> <ptero_db_user> <ptero_db_pass>
 */

if ($argc < 5) {
    fwrite(STDERR, "Usage: PTERO_DB_PASS=xxx php migrate-data.php <host> <port> <database> <user>\n");
    exit(1);
}

[, $dbHost, $dbPort, $dbName, $dbUser] = $argv;
$dbPass = getenv('PTERO_DB_PASS') ?: '';

try {
    $ptero = new PDO("mysql:host={$dbHost};port={$dbPort};dbname={$dbName};charset=utf8mb4", $dbUser, $dbPass);
    $ptero->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
} catch (PDOException $e) {
    fwrite(STDERR, "Cannot connect to Pterodactyl DB: " . $e->getMessage() . "\n");
    exit(1);
}

// Bootstrap Laravel (script runs from the Skyport panel root)
require __DIR__ . '/vendor/autoload.php';
$app = require __DIR__ . '/bootstrap/app.php';
$app->make('Illuminate\Contracts\Console\Kernel')->bootstrap();

// Use WAL mode for better write performance on SQLite
if (config('database.default') === 'sqlite') {
    DB::statement('PRAGMA journal_mode=WAL');
    DB::statement('PRAGMA synchronous=NORMAL');
}

use App\Models\Cargo;
use App\Models\User;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

$results = [
    'users' => 0,
    'locations' => 0,
    'nodes' => 0,
    'cargo' => 0,
    'allocations' => 0,
    'servers' => 0,
];

// ── Users ──
$users = $ptero->query("SELECT id, COALESCE(name_first,'') as name_first, COALESCE(name_last,'') as name_last, email, password, root_admin, created_at FROM users")->fetchAll(PDO::FETCH_ASSOC);

$userMap = [];
foreach ($users as $u) {
    $name = trim($u['name_first'] . ' ' . $u['name_last']) ?: $u['email'];
    $existing = DB::table('users')->where('email', $u['email'])->first();
    if ($existing) {
        $userMap[$u['id']] = $existing->id;
        continue;
    }
    $id = DB::table('users')->insertGetId([
        'name' => $name,
        'email' => $u['email'],
        'password' => $u['password'],
        'is_admin' => (bool) $u['root_admin'],
        'created_at' => $u['created_at'],
        'updated_at' => $u['created_at'],
    ]);
    $userMap[$u['id']] = $id;
    $results['users']++;
}

// ── Locations ──
$locations = $ptero->query("SELECT id, short FROM locations")->fetchAll(PDO::FETCH_ASSOC);

$locationMap = [];
foreach ($locations as $loc) {
    $name = $loc['short'] ?: 'Default';
    $country = 'Unknown';
    if ($name === '--') $name = 'Default';
    if (preg_match('/,\s*([A-Z]{2})$/', $loc['short'], $m)) {
        $country = $m[1];
        $name = trim(preg_replace('/,\s*[A-Z]{2}$/', '', $loc['short']));
    }
    $existing = DB::table('locations')->where('name', $name)->first();
    if ($existing) {
        $locationMap[$loc['id']] = $existing->id;
        continue;
    }
    $id = DB::table('locations')->insertGetId([
        'name' => $name,
        'country' => $country,
        'created_at' => now(),
        'updated_at' => now(),
    ]);
    $locationMap[$loc['id']] = $id;
    $results['locations']++;
}

// ── Nodes ──
$nodes = $ptero->query("SELECT id, name, fqdn, daemonListen, daemonSFTP, scheme, location_id FROM nodes")->fetchAll(PDO::FETCH_ASSOC);

$nodeMap = [];
foreach ($nodes as $n) {
    $useSsl = $n['scheme'] === 'https';
    $locationId = $locationMap[$n['location_id']] ?? DB::table('locations')->value('id');
    $fqdn = $n['fqdn'];

    // Handle duplicate FQDNs
    if (DB::table('nodes')->where('fqdn', $fqdn)->exists()) {
        $fqdn = $fqdn . ':' . $n['daemonListen'];
    }

    $existing = DB::table('nodes')->where('name', $n['name'])->first();
    if ($existing) {
        $nodeMap[$n['id']] = $existing->id;
        continue;
    }

    $id = DB::table('nodes')->insertGetId([
        'location_id' => $locationId,
        'name' => $n['name'],
        'fqdn' => $fqdn,
        'daemon_port' => (int) $n['daemonListen'],
        'sftp_port' => (int) $n['daemonSFTP'],
        'use_ssl' => $useSsl,
        'created_at' => now(),
        'updated_at' => now(),
    ]);
    $nodeMap[$n['id']] = $id;
    $results['nodes']++;
}

// ── Eggs → Cargo ──
$eggs = $ptero->query("SELECT id, name, author, startup, COALESCE(config_stop,'') as config_stop, COALESCE(docker_images,'{}') as docker_images, COALESCE(script_container,'') as script_container, COALESCE(script_entry,'') as script_entry, COALESCE(script_install,'') as script_install FROM eggs")->fetchAll(PDO::FETCH_ASSOC);

$cargoMap = [];
foreach ($eggs as $egg) {
    $slug = Str::slug($egg['name']);
    $existing = DB::table('cargos')->where('slug', $slug)->first();
    if ($existing) {
        $cargoMap[$egg['id']] = $existing->id;
        continue;
    }

    $dockerImages = json_decode($egg['docker_images'], true) ?: [];

    $definition = [
        'startup' => $egg['startup'],
        'stop' => $egg['config_stop'] ?: 'stop',
    ];

    $id = DB::table('cargos')->insertGetId([
        'name' => $egg['name'],
        'slug' => $slug,
        'author' => $egg['author'] ?: 'unknown',
        'description' => 'Migrated from Pterodactyl',
        'source_type' => 'native',
        'startup_command' => $egg['startup'],
        'config_stop' => $egg['config_stop'] ?: null,
        'docker_images' => json_encode($dockerImages),
        'install_script' => $egg['script_install'] ?: null,
        'install_container' => $egg['script_container'] ?: null,
        'install_entrypoint' => $egg['script_entry'] ?: null,
        'definition' => json_encode($definition),
        'cargofile' => json_encode($definition),
        'created_at' => now(),
        'updated_at' => now(),
    ]);
    $cargoMap[$egg['id']] = $id;
    $results['cargo']++;
}

// ── Allocations ──
$allocations = $ptero->query("SELECT id, node_id, ip, port, ip_alias FROM allocations")->fetchAll(PDO::FETCH_ASSOC);

$allocMap = [];
$allocBatch = [];
$allocPteroIds = [];

foreach ($allocations as $a) {
    $nodeId = $nodeMap[$a['node_id']] ?? null;
    if (!$nodeId) continue;

    $existing = DB::table('allocations')
        ->where('node_id', $nodeId)
        ->where('bind_ip', $a['ip'])
        ->where('port', $a['port'])
        ->first();

    if ($existing) {
        $allocMap[$a['id']] = $existing->id;
        continue;
    }

    $allocBatch[] = [
        'node_id' => $nodeId,
        'bind_ip' => $a['ip'],
        'port' => (int) $a['port'],
        'ip_alias' => $a['ip_alias'] ?: null,
        'created_at' => now()->toDateTimeString(),
        'updated_at' => now()->toDateTimeString(),
    ];
    $allocPteroIds[] = $a;
    $results['allocations']++;
}

// Bulk insert in chunks with error recovery
$allocInserted = 0;
foreach (array_chunk($allocBatch, 50) as $i => $chunk) {
    try {
        DB::table('allocations')->insert($chunk);
        $allocInserted += count($chunk);
    } catch (\Throwable $e) {
        fwrite(STDERR, "Chunk {$i} failed ({$e->getMessage()}), trying individually...\n");
        foreach ($chunk as $row) {
            try {
                DB::table('allocations')->insert($row);
                $allocInserted++;
            } catch (\Throwable $e2) {
                // Skip
            }
        }
    }
}
$results['allocations'] = $allocInserted;

// Build alloc map after insert
foreach ($allocPteroIds as $a) {
    $nodeId = $nodeMap[$a['node_id']] ?? null;
    if (!$nodeId) continue;
    $skyportAlloc = DB::table('allocations')
        ->where('node_id', $nodeId)
        ->where('bind_ip', $a['ip'])
        ->where('port', $a['port'])
        ->first();
    if ($skyportAlloc) {
        $allocMap[$a['id']] = $skyportAlloc->id;
    }
}

// ── Servers ──
$servers = $ptero->query("SELECT id, name, memory, disk, cpu, owner_id, node_id, egg_id, allocation_id, image FROM servers")->fetchAll(PDO::FETCH_ASSOC);

foreach ($servers as $s) {
    try {
        $nodeId = $nodeMap[$s['node_id']] ?? null;
        $cargoId = $cargoMap[$s['egg_id']] ?? null;
        $userId = $userMap[$s['owner_id']] ?? null;
        $allocId = $allocMap[$s['allocation_id']] ?? null;

        if (!$nodeId || !$cargoId || !$userId) {
            fwrite(STDERR, "Skipping server {$s['name']} (missing mapping: node=" . ($nodeId ?? 'null') . " cargo=" . ($cargoId ?? 'null') . " user=" . ($userId ?? 'null') . ")\n");
            continue;
        }

        DB::table('servers')->insert([
            'user_id' => $userId,
            'node_id' => $nodeId,
            'cargo_id' => $cargoId,
            'allocation_id' => $allocId,
            'name' => $s['name'],
            'docker_image' => $s['image'],
            'memory_mib' => (int) $s['memory'],
            'cpu_limit' => (int) $s['cpu'],
            'disk_mib' => (int) $s['disk'],
            'status' => 'offline',
            'created_at' => now(),
            'updated_at' => now(),
        ]);
        $results['servers']++;
    } catch (\Throwable $e) {
        fwrite(STDERR, "Failed to migrate server {$s['name']}: {$e->getMessage()}\n");
    }
}

// Output results as simple key=value
foreach ($results as $key => $count) {
    echo "{$key}={$count}\n";
}
