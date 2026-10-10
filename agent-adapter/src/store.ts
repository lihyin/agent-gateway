import { mkdir, open, readFile, rename, rm, chmod } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { userInfo } from "node:os";
import { Bridge, type BridgeState } from "./bridge.js";

async function protect(file: string): Promise<void> {
  if (process.platform === "win32") {
    await promisify(execFile)(
      "icacls.exe",
      [file, "/inheritance:r", "/grant:r", `${userInfo().username}:F`],
      { windowsHide: true },
    );
  } else {
    await chmod(file, 0o600);
  }
}

export async function openBridge(
  path: string,
): Promise<{ bridge: Bridge; close: () => Promise<void> }> {
  const file = resolve(path);
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  const lock = await open(`${file}.lock`, "wx", 0o600);
  const close = async () => {
    await lock.close();
    await rm(`${file}.lock`, { force: true });
  };
  try {
    const save = async (state: BridgeState) => {
      const tmp = `${file}.tmp`;
      await rm(tmp, { force: true });
      const handle = await open(tmp, "wx", 0o600);
      try {
        await protect(tmp);
        await handle.writeFile(JSON.stringify({ version: 1, state }));
        await handle.sync();
      } finally {
        await handle.close();
      }
      await rename(tmp, file);
      await protect(file);
    };
    let saved;
    try {
      saved = JSON.parse(await readFile(file, "utf8"));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT")
        throw new Error("storage_unavailable");
    }
    if (saved && saved.version !== 1) throw new Error("storage_unavailable");
    const bridge = saved
      ? new Bridge(saved.state, save)
      : await Bridge.create(save);
    return { bridge, close };
  } catch (error) {
    await close();
    throw error;
  }
}
