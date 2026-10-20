/** Job presentation and tracking. Everything shown comes from the server's job record. */
import type { Api, JobResponse, JobStatus } from "./api";

export const TERMINAL: readonly JobStatus[] = ["completed", "failed", "cancelled", "interrupted"];

export function isTerminal(status: JobStatus): boolean {
  return TERMINAL.includes(status);
}

export function formatBytes(value: number | null | undefined): string | null {
  if (value === null || value === undefined || !Number.isFinite(value) || value < 0) return null;
  const units = ["B", "KB", "MB", "GB"];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${unit === 0 ? Math.round(size) : size.toFixed(1)} ${units[unit]}`;
}

export function formatEta(seconds: number | null | undefined): string {
  if (seconds === null || seconds === undefined || !Number.isFinite(seconds)) return "";
  return seconds >= 60 ? `${Math.floor(seconds / 60)}m ${seconds % 60}s left` : `${seconds}s left`;
}

export interface JobView {
  label: string;
  detail: string;
  percent: number;
  indeterminate: boolean;
  terminal: boolean;
  canCancel: boolean;
  canRetry: boolean;
  canSave: boolean;
}

const LABELS: Record<JobStatus, string> = {
  queued: "Waiting in queue…",
  validating: "Checking link…",
  fetching_metadata: "Reading video info…",
  downloading: "Downloading",
  merging: "Merging audio and video…",
  verifying: "Verifying file…",
  completed: "Ready",
  failed: "Failed",
  cancelled: "Cancelled",
  interrupted: "Interrupted",
};

export function describeJob(job: JobResponse): JobView {
  const percent = Math.max(0, Math.min(100, job.progress?.percent ?? 0));
  const details: string[] = [];
  let label = LABELS[job.status] ?? job.status;
  if (job.status === "downloading") {
    label = `Downloading ${Math.round(percent)}%`;
    const speed = formatBytes(job.progress.speed_bps);
    if (speed) details.push(`${speed}/s`);
    const eta = formatEta(job.progress.eta_seconds);
    if (eta) details.push(eta);
  }
  if (job.status === "queued" && job.attempt > 0) {
    label = `Retrying (attempt ${job.attempt + 1} of ${job.max_attempts})…`;
  }
  if ((job.status === "failed" || job.status === "cancelled" || job.status === "interrupted") && job.error?.message) {
    label = job.error.message;
  }
  const terminal = isTerminal(job.status);
  return {
    label,
    detail: details.join(" · "),
    percent,
    indeterminate: ["queued", "validating", "fetching_metadata", "merging", "verifying"].includes(job.status),
    terminal,
    canCancel: !terminal,
    canRetry: job.status === "cancelled" || job.status === "interrupted" || (job.status === "failed" && job.error?.retryable !== false),
    canSave: job.status === "completed" && !!job.result,
  };
}

export interface WatchOptions {
  intervalMs?: number;
  maxConsecutiveFailures?: number;
  schedule?: (callback: () => void, ms: number) => unknown;
  cancelSchedule?: (handle: unknown) => void;
}

/**
 * Poll a job until it is terminal. Polling (not SSE) because React Native has no native
 * EventSource and polling survives flaky mobile networks. Transient network errors are
 * retried with a growing delay; 401/404 end the watch with a synthetic failed state.
 */
export function watchJob(
  api: Api,
  id: string,
  onUpdate: (job: JobResponse) => void,
  options: WatchOptions = {},
): { stop: () => void } {
  const interval = options.intervalMs ?? 1000;
  const maxFailures = options.maxConsecutiveFailures ?? 6;
  const schedule = options.schedule ?? ((cb: () => void, ms: number) => setTimeout(cb, ms));
  const cancelSchedule = options.cancelSchedule ?? ((h: unknown) => clearTimeout(h as ReturnType<typeof setTimeout>));
  let stopped = false;
  let handle: unknown = null;
  let failures = 0;

  async function tick(): Promise<void> {
    if (stopped) return;
    try {
      const job = await api.getJob(id);
      failures = 0;
      if (stopped) return;
      onUpdate(job);
      if (!isTerminal(job.status)) handle = schedule(() => void tick(), interval);
    } catch (error) {
      if (stopped) return;
      failures += 1;
      const status = (error as { status?: number }).status;
      if (status === 404 || status === 401 || failures >= maxFailures) {
        onUpdate({
          id,
          status: "failed",
          platform: "",
          quality: "",
          progress: { percent: 0 },
          attempt: 0,
          max_attempts: 1,
          error: {
            code: "client_error",
            message: (error as Error).message || "Lost contact with the server.",
            retryable: status !== 404,
          },
          created_at: "",
          updated_at: "",
        });
        return;
      }
      handle = schedule(() => void tick(), interval * (failures + 1));
    }
  }

  void tick();
  return {
    stop() {
      stopped = true;
      if (handle !== null) cancelSchedule(handle);
    },
  };
}

/** A local cache file name: unique per job, free of path separators and control characters. */
export function safeLocalName(filename: string, jobId: string): string {
  const cleaned =
    filename
      // eslint-disable-next-line no-control-regex
      .replace(/[\/:*?"<>|\u0000-\u001f]/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .replace(/^\.+/, "") || "video";
  const prefix = jobId.replace(/[^A-Za-z0-9]/g, "").slice(0, 8) || "job";
  return `${prefix}-${cleaned.slice(-120)}`;
}

export function mimeFor(filename: string): string {
  const extension = filename.split(".").pop()?.toLowerCase() ?? "";
  const types: Record<string, string> = {
    mp4: "video/mp4",
    mkv: "video/x-matroska",
    webm: "video/webm",
    mp3: "audio/mpeg",
    m4a: "audio/mp4",
  };
  return types[extension] ?? "application/octet-stream";
}
