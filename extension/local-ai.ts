import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { promisify } from "node:util";
import * as os from "node:os";
import * as path from "node:path";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const execFileAsync = promisify(execFile);
const tools = path.join(os.homedir(), ".local", "bin", "local-ai-tools.py");
const agentDir = process.env.PI_CODING_AGENT_DIR ?? path.join(os.homedir(), ".local", "share", "local-ai", "pi-agent");
const settingsPath = path.join(agentDir, "settings.json");
const modelsPath = path.join(agentDir, "models.json");

function modelInfo(): { id: string; context: number } {
  let id = "";
  let context = 65536;
  try {
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    if (typeof settings.defaultModel === "string") id = settings.defaultModel;
  } catch {}
  try {
    const models = JSON.parse(readFileSync(modelsPath, "utf8"));
    const list = models?.providers?.ollama?.models;
    if (Array.isArray(list)) {
      const match = list.find((model: any) => model?.id === id) ?? list[0];
      if (!id && typeof match?.id === "string") id = match.id;
      if (Number.isFinite(match?.contextWindow)) context = Number(match.contextWindow);
    }
  } catch {}
  return { id, context };
}

async function runTool(action: string, signal?: AbortSignal): Promise<string | null> {
  if (!existsSync(tools)) return null;
  const model = modelInfo();
  const args = action === "benchmark"
    ? [tools, "benchmark", "--model", model.id, "--num-ctx", String(model.context), "--runs", "3", "--output-tokens", "128"]
    : [tools, action];
  const env = { ...process.env } as Record<string, string>;
  if (model.id) env.LOCAL_AI_MODEL = model.id;
  try {
    const result = await execFileAsync("python3", args, {
      encoding: "utf8",
      timeout: action === "benchmark" ? 180000 : 30000,
      maxBuffer: 4 * 1024 * 1024,
      env,
      signal,
    });
    return String(result.stdout ?? "").trim() || "(no output)";
  } catch (error: any) {
    if (signal?.aborted) return "Cancelled";
    const stdout = error?.stdout?.toString()?.trim() ?? "";
    const stderr = error?.stderr?.toString()?.trim() ?? "";
    return ["local-ai-tools.py failed", stdout, stderr].filter(Boolean).join("\n");
  }
}

async function getJson(url: string): Promise<any | null> {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(3000) });
    if (!response.ok) return null;
    return await response.json();
  } catch { return null; }
}

async function fallback(action: string): Promise<string | null> {
  const version = await getJson("http://127.0.0.1:11434/api/version");
  const running = await getJson("http://127.0.0.1:11434/api/ps");
  const tags = await getJson("http://127.0.0.1:11434/api/tags");
  if (action === "models") {
    return ["# Ollama models", JSON.stringify({ version, running, installed: tags }, null, 2)].join("\n\n");
  }
  if (action !== "health") return null;
  let webui = "offline";
  try {
    const response = await fetch("http://127.0.0.1:3000/", { signal: AbortSignal.timeout(3000), redirect: "manual" });
    webui = `reachable (${response.status})`;
  } catch {}
  let gpu = "unavailable";
  let memory = "unavailable";
  try { gpu = String((await execFileAsync("bash", ["-lc", "nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null || /usr/lib/wsl/lib/nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null || true"], { encoding: "utf8", timeout: 5000 })).stdout).trim() || "unavailable"; } catch {}
  try { memory = String((await execFileAsync("bash", ["-lc", "grep -E 'MemTotal|MemAvailable' /proc/meminfo"], { encoding: "utf8", timeout: 3000 })).stdout).trim() || "unavailable"; } catch {}
  return ["# Local AI health fallback", `Ollama: ${version ? "online" : "offline"}`, `Open WebUI: ${webui}`, "", "GPU:", gpu, "", "Memory:", memory, "", "Loaded models:", JSON.stringify(running, null, 2)].join("\n");
}

export default function localAI(pi: ExtensionAPI) {
  pi.registerTool({
    name: "local_ai_status",
    label: "Local AI Status",
    description: "Inspect Local AI health, Ollama models, or run the configured quick benchmark.",
    promptSnippet: "Inspect Local AI runtime health, models, or benchmark state",
    promptGuidelines: ["Use local_ai_status when the user asks about Local AI runtime health, Ollama state, Open WebUI state, loaded models, GPU/RAM status, or a quick local benchmark."],
    parameters: Type.Object({
      action: Type.Optional(Type.Union([Type.Literal("health"), Type.Literal("models"), Type.Literal("benchmark")]))
    }),
    async execute(_toolCallId, params, signal) {
      const action = params.action ?? "health";
      let text = await runTool(action, signal);
      if (!text) text = await fallback(action);
      if (!text) text = `${action} is unavailable because ${tools} is not installed and no safe fallback exists.`;
      return { content: [{ type: "text", text }], details: { action, source: existsSync(tools) ? "local-ai-tools.py" : "fallback" } };
    },
  });
}
