import http from "node:http";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(fileURLToPath(new URL("./dist/", import.meta.url)));
http
  .createServer(async (request, response) => {
    try {
      let file = path.resolve(
        root,
        "." +
          decodeURIComponent(new URL(request.url, "http://localhost").pathname),
      );
      if (file !== root && !file.startsWith(root + path.sep)) {
        throw new Error("Invalid path");
      }
      if ((await stat(file)).isDirectory())
        file = path.join(file, "index.html");
      const content = await readFile(file);
      response.setHeader(
        "Content-Type",
        file.endsWith(".css")
          ? "text/css"
          : file.endsWith(".svg")
            ? "image/svg+xml"
            : file.endsWith(".txt")
              ? "text/plain; charset=utf-8"
              : "text/html; charset=utf-8",
      );
      response.end(content);
    } catch {
      response.statusCode = 404;
      response.end("Not found");
    }
  })
  .listen(4173, "127.0.0.1", () => console.log("http://127.0.0.1:4173"));
