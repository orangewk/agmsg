import { accessSync, constants, existsSync } from "node:fs";
import { delimiter, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const project = process.argv[2];
if (!project) {
  process.stderr.write("agmsg qwen hook: missing project path\n");
  process.exit(2);
}

const here = fileURLToPath(new URL(".", import.meta.url));
const checkInbox = resolve(here, "../../../check-inbox.sh");
if (!existsSync(checkInbox)) {
  process.stderr.write(`agmsg qwen hook: check-inbox.sh not found: ${checkInbox}\n`);
  process.exit(2);
}

function executable(path) {
  if (!path) return false;
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function windowsGitBash() {
  const programFiles = process.env.ProgramFiles || "C:\\Program Files";
  const programFilesX86 =
    process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)";
  const explicit = [process.env.GIT_BASH, process.env.AGMSG_BASH];
  const common = [
    join(programFiles, "Git", "bin", "bash.exe"),
    join(programFiles, "Git", "usr", "bin", "bash.exe"),
    join(programFilesX86, "Git", "bin", "bash.exe"),
    join(programFilesX86, "Git", "usr", "bin", "bash.exe"),
  ];
  const fromPath = (process.env.Path || process.env.PATH || "")
    .split(delimiter)
    .filter(Boolean)
    .map((dir) => join(dir, "bash.exe"))
    .filter((path) => !path.toLowerCase().includes("\\windowsapps\\"));

  return [...explicit, ...common, ...fromPath].find(executable);
}

const bash =
  process.platform === "win32"
    ? windowsGitBash()
    : process.env.GIT_BASH || process.env.AGMSG_BASH || "bash";

if (!bash) {
  process.stderr.write(
    "agmsg qwen hook: Git Bash not found; set GIT_BASH or AGMSG_BASH\n",
  );
  process.exit(127);
}

const shellPath = (path) =>
  process.platform === "win32" ? path.replaceAll("\\", "/") : path;

const child = spawn(
  bash,
  [shellPath(checkInbox), "qwen", shellPath(project)],
  {
    env: process.env,
    stdio: "inherit",
    windowsHide: true,
  },
);

child.on("error", (error) => {
  process.stderr.write(`agmsg qwen hook: ${error.message}\n`);
  process.exitCode = 1;
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.stderr.write(`agmsg qwen hook: child exited on ${signal}\n`);
    process.exitCode = 1;
  } else {
    process.exitCode = code ?? 1;
  }
});
