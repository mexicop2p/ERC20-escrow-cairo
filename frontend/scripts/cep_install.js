const { spawn } = require("node:child_process");

const candidates = [process.env.CEP_PYTHON_BIN, "python3", "python"].filter(Boolean);

if (!candidates.length) {
  console.error("No python executables provided or detected.");
  process.exit(1);
}

const target = candidates.shift();

function installWith(binary) {
  const child = spawn(binary, ["-m", "pip", "install", "git+https://github.com/cuenca-mx/cep-python"], {
    stdio: "inherit",
  });

  child.on("error", (err) => {
    if (candidates.length === 0) {
      console.error(`Failed to run '${binary}':`, err.message);
      process.exit(1);
    }
    console.warn(`Unable to run '${binary}', retrying with '${candidates[0]}'...`);
    installWith(candidates.shift());
  });

  child.on("exit", (code) => {
    if (code === 0) return;
    if (candidates.length === 0) {
      console.error(`CEP install failed with '${binary}' (exit ${code}).`);
      process.exit(code ?? 1);
    }
    console.warn(`CEP install failed with '${binary}' (exit ${code}), retrying with '${candidates[0]}'...`);
    installWith(candidates.shift());
  });
}

installWith(target);
