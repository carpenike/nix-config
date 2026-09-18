import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";

try {
  const { values } = parseArgs({
    options: {
      config: { type: "string" },
      "confirm-new-installation": { type: "string" },
      "confirm-existing-installation": { type: "string" },
    },
  });
  const config = JSON.parse(fs.readFileSync(values.config, "utf8"));
  const initialize = values["confirm-new-installation"] !== undefined;
  if (
    initialize === (values["confirm-existing-installation"] !== undefined) ||
    config.installation !== values[initialize ? "confirm-new-installation" : "confirm-existing-installation"]
  ) throw new Error();
  const directory = config.settings.deny.state_directory;
  if (initialize) {
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
  } else if (
    !fs.existsSync(path.join(directory, "owner.json")) ||
    !fs.existsSync(path.join(directory, "admission.sqlite"))
  ) {
    throw new Error();
  }
  const { AtriumDenyStore } = await import(pathToFileURL(config.store_module).href);
  const store = new AtriumDenyStore(directory, config.settings.issuer, Math.floor(Date.now() / 1000));
  store.close();
  console.log(JSON.stringify({ validated: "whiskey-deny", initialized: initialize, household_service_started: false }));
} catch {
  console.error("atrium_whiskey_initialization_rejected");
  process.exitCode = 1;
}
