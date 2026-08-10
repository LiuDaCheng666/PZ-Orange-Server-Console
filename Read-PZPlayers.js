const { DatabaseSync } = require('node:sqlite');

const databasePath = process.argv[2];
if (!databasePath) throw new Error('Database path is required.');

const database = new DatabaseSync(databasePath, { readOnly: true });
try {
  const players = database.prepare(`
    SELECT
      whitelist.username,
      COALESCE(role.name, 'user') AS role,
      whitelist.lastConnection,
      whitelist.steamid AS steamId
    FROM whitelist
    LEFT JOIN role ON role.id = whitelist.role
    ORDER BY whitelist.username COLLATE NOCASE
  `).all();
  process.stdout.write(JSON.stringify(players));
} finally {
  database.close();
}
