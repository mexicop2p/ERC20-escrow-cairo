import { spawn } from "node:child_process";
import path from "node:path";
import { NextResponse } from "next/server";
import { cepSchema } from "../../../lib/cep";

const scriptPath = path.join(process.cwd(), "scripts", "cep_validate.py");
const pythonExecutable = process.env.CEP_PYTHON_BIN ?? "python3";

export async function POST(request: Request) {
  const body = await request.json();
  const parsed = cepSchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json({ valid: false, error: parsed.error.errors[0]?.message }, { status: 400 });
  }

  const output = await runPythonValidator(parsed.data);
  return NextResponse.json(output);
}

function runPythonValidator(payload: unknown): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const child = spawn(pythonExecutable, [scriptPath], { stdio: ["pipe", "pipe", "pipe"] });

    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("close", () => {
      if (stderr) {
        console.warn("CEP validation stderr", stderr);
      }
      try {
        const parsed = JSON.parse(stdout || "{}");
        resolve(parsed);
      } catch (error) {
        reject(error);
      }
    });

    child.stdin.write(JSON.stringify(payload));
    child.stdin.end();
  });
}
