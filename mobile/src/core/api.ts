/** Typed client for the Namao v1 download-job API (same contract as the web and desktop clients). */

export type JobStatus =
  | "queued"
  | "validating"
  | "fetching_metadata"
  | "downloading"
  | "merging"
  | "verifying"
  | "completed"
  | "failed"
  | "cancelled"
  | "interrupted";

export interface ApiErrorBody {
  code: string;
  message: string;
  retryable: boolean;
  detail?: string | null;
}

export interface FormatOption {
  id: string;
  label: string;
  kind: "video" | "audio";
  height?: number | null;
  note: string;
  size_bytes?: number | null;
  size_estimated: boolean;
  needs_merge: boolean;
}

export interface MetadataResponse {
  platform: string;
  title: string;
  uploader: string;
  duration_seconds: number;
  thumbnail?: string | null;
  formats: FormatOption[];
  ffmpeg: boolean;
}

export interface JobProgress {
  percent: number;
  downloaded_bytes?: number | null;
  total_bytes?: number | null;
  speed_bps?: number | null;
  eta_seconds?: number | null;
}

export interface JobResult {
  filename: string;
  size_bytes: number;
  height?: number | null;
  duration_seconds?: number | null;
  download_url: string;
}

export interface JobResponse {
  id: string;
  status: JobStatus;
  platform: string;
  quality: string;
  title?: string | null;
  progress: JobProgress;
  attempt: number;
  max_attempts: number;
  retry_at?: string | null;
  error?: ApiErrorBody | null;
  result?: JobResult | null;
  created_at: string;
  updated_at: string;
  expires_at?: string | null;
}

export class ApiRequestError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code: string | null,
    readonly retryable: boolean,
  ) {
    super(message);
    this.name = "ApiRequestError";
  }
}

export interface ApiConfig {
  baseUrl: string;
  apiKey?: string | null;
  fetchImpl?: typeof fetch;
}

export interface FileRequest {
  url: string;
  headers: Record<string, string>;
}

export interface Api {
  metadata(url: string): Promise<MetadataResponse>;
  createDownload(url: string, quality: string, idempotencyKey: string): Promise<JobResponse>;
  getJob(id: string): Promise<JobResponse>;
  cancel(id: string): Promise<JobResponse>;
  /** URL + headers for fetching the finished file (the API key must not travel in the URL). */
  fileRequest(id: string): FileRequest;
}

const PREFIX = "/api/v1/downloads";

export function createApi(config: ApiConfig): Api {
  const fetchImpl = config.fetchImpl ?? fetch;

  function authHeaders(): Record<string, string> {
    return config.apiKey ? { "X-API-Key": config.apiKey } : {};
  }

  async function request<T>(method: string, path: string, body?: unknown, extra?: Record<string, string>): Promise<T> {
    const response = await fetchImpl(config.baseUrl + path, {
      method,
      headers: { "Content-Type": "application/json", ...authHeaders(), ...extra },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    let data: unknown = null;
    try {
      data = await response.json();
    } catch {
      data = null;
    }
    if (!response.ok) {
      const error = (data as { error?: Partial<ApiErrorBody> } | null)?.error;
      throw new ApiRequestError(
        error?.message ?? `Request failed (${response.status}).`,
        response.status,
        error?.code ?? null,
        error?.retryable ?? false,
      );
    }
    return data as T;
  }

  return {
    metadata: (url) => request<MetadataResponse>("POST", `${PREFIX}/metadata`, { url }),
    createDownload: (url, quality, idempotencyKey) =>
      request<JobResponse>("POST", PREFIX, { url, quality }, { "Idempotency-Key": idempotencyKey }),
    getJob: (id) => request<JobResponse>("GET", `${PREFIX}/${encodeURIComponent(id)}`),
    cancel: (id) => request<JobResponse>("POST", `${PREFIX}/${encodeURIComponent(id)}/cancel`),
    fileRequest: (id) => ({
      url: `${config.baseUrl}${PREFIX}/${encodeURIComponent(id)}/file`,
      headers: authHeaders(),
    }),
  };
}
