import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";

try {
  const { values } = parseArgs({
    options: {
      config: { type: "string" },
      "confirm-new-installation": { type: "string" },
    },
  });
  const config = JSON.parse(fs.readFileSync(values.config, "utf8"));
  if (config.installation !== values["confirm-new-installation"]) throw new Error();
  const directory = config.settings.deny.state_directory;
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  if (fs.readdirSync(directory).length !== 0) throw new Error();
  const descriptor = fs.openSync(
    path.join(directory, "initialization.started"),
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW,
    0o600,
  );
  try {
    fs.writeFileSync(descriptor, `${config.installation}\n`);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  const { AtriumDenyStore } = await import(pathToFileURL(config.store_module).href);
  const store = new AtriumDenyStore(directory, config.settings.issuer, Math.floor(Date.now() / 1000));
  store.close();
  console.log(JSON.stringify({ initialized: "whiskey-deny", household_service_started: false }));
} catch {
  console.error("atrium_whiskey_initialization_rejected");
  process.exitCode = 1;
}
