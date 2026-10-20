import { ApiRequestError, createApi, type JobResponse, type JobStatus } from "../src/core/api";
import { describeJob, formatBytes, isTerminal, mimeFor, safeLocalName, watchJob } from "../src/core/jobs";
import { detectPlatform, extractVideoUrl, normalizeServerUrl, parseUrl, ServerUrlError } from "../src/core/urls";

function job(status: JobStatus, extra: Partial<JobResponse> = {}): JobResponse {
  return {
    id: "job12345678901234567890", status, platform: "youtube", quality: "720", progress: { percent: 0 },
    attempt: 0, max_attempts: 3, created_at: "", updated_at: "", ...extra,
  };
}

const tick = () => new Promise<void>((resolve) => setImmediate(() => resolve()));

function response(status: number, body: unknown): Response {
  return { ok: status >= 200 && status < 300, status, json: () => Promise.resolve(body) } as unknown as Response;
}

describe("shared links", () => {
  it("extracts the supported link from share text", () => {
    expect(extractVideoUrl("Watch this! https://youtu.be/abc123?t=5 so good")).toBe("https://youtu.be/abc123?t=5");
    expect(extractVideoUrl("(https://www.tiktok.com/@u/video/1).")).toBe("https://www.tiktok.com/@u/video/1");
    expect(extractVideoUrl("see https://evil.example/?u=youtube.com then https://x.com/u/status/1")).toBe("https://x.com/u/status/1");
  });

  it("returns null when nothing supported is shared", () => {
    for (const text of [null, undefined, "", "no link here", "https://example.com/video", "https://youtube.com.evil.example/x"]) {
      expect(extractVideoUrl(text)).toBeNull();
    }
  });

  it("detects platforms by parsed host, not by substring", () => {
    expect(detectPlatform("https://m.youtube.com/watch?v=1")).toBe("youtube");
    expect(detectPlatform("fb.watch/abc")).toBe("facebook");
    expect(detectPlatform("https://notyoutube.com/x")).toBeNull();
    expect(detectPlatform("https://user:pw@youtube.com/x")).toBeNull();
  });

  it("parses urls strictly", () => {
    expect(parseUrl("https://Example.COM:8443/a/b?c=1#d")).toEqual({ scheme: "https", host: "example.com", port: 8443, path: "/a/b" });
    for (const bad of ["ftp://x.com", "https://", "https://a b.com", "https://x.com:99999", "javascript:alert(1)", "https://-bad.com"]) {
      expect(parseUrl(bad)).toBeNull();
    }
  });
});

describe("server address", () => {
  it("normalizes https addresses", () => {
    expect(normalizeServerUrl(" namao.example.com/ ")).toBe("https://namao.example.com");
    expect(normalizeServerUrl("https://namao.example.com:8443/app/?x=1#y")).toBe("https://namao.example.com:8443/app");
  });

  it("allows cleartext http only on the local network", () => {
    for (const ok of ["http://192.168.1.20:8000", "http://10.0.0.5", "http://172.16.4.1:8000", "http://localhost:8000", "http://nas.local:8000"]) {
      expect(() => normalizeServerUrl(ok)).not.toThrow();
    }
    for (const bad of ["http://namao.example.com", "http://8.8.8.8", "http://172.32.0.1", "http://192.169.1.1"]) {
      expect(() => normalizeServerUrl(bad)).toThrow(ServerUrlError);
    }
  });

  it("rejects empty and malformed input", () => {
    for (const bad of ["", "   ", "https://user:pw@host.example", "ftp://host", "http://"]) {
      expect(() => normalizeServerUrl(bad)).toThrow(ServerUrlError);
    }
  });
});

describe("api client", () => {
  it("sends the key as a header, never in the URL, and an idempotency key on create", async () => {
    const calls: { url: string; init: RequestInit }[] = [];
    const api = createApi({
      baseUrl: "https://s.example", apiKey: "k3y",
      fetchImpl: (async (url: string, init: RequestInit) => {
        calls.push({ url, init });
        return response(202, job("queued"));
      }) as unknown as typeof fetch,
    });
    await api.createDownload("https://youtu.be/x", "1080", "idem-12345678");
    expect(calls[0].url).toBe("https://s.example/api/v1/downloads");
    expect((calls[0].init.headers as Record<string, string>)["X-API-Key"]).toBe("k3y");
    expect((calls[0].init.headers as Record<string, string>)["Idempotency-Key"]).toBe("idem-12345678");
    expect(JSON.parse(calls[0].init.body as string)).toEqual({ url: "https://youtu.be/x", quality: "1080" });
    const file = api.fileRequest("a/b");
    expect(file.url).toBe("https://s.example/api/v1/downloads/a%2Fb/file");
    expect(file.url).not.toContain("k3y");
    expect(file.headers).toEqual({ "X-API-Key": "k3y" });
  });

  it("turns the error envelope into an ApiRequestError", async () => {
    const api = createApi({
      baseUrl: "https://s.example",
      fetchImpl: (async () =>
        response(422, { error: { code: "geo_restricted", message: "Not in this region.", retryable: false } })) as unknown as typeof fetch,
    });
    await expect(api.metadata("https://youtu.be/x")).rejects.toMatchObject({
      name: "ApiRequestError", message: "Not in this region.", status: 422, code: "geo_restricted", retryable: false,
    });
    const broken = createApi({
      baseUrl: "https://s.example",
      fetchImpl: (async () => ({ ok: false, status: 502, json: () => Promise.reject(new Error("x")) })) as unknown as typeof fetch,
    });
    await expect(broken.getJob("abc")).rejects.toBeInstanceOf(ApiRequestError);
  });
});

describe("job presentation", () => {
  it("shows real progress and never calls a failed job successful", () => {
    const downloading = describeJob(job("downloading", { progress: { percent: 42.4, speed_bps: 2097152, eta_seconds: 90 } }));
    expect(downloading.label).toBe("Downloading 42%");
    expect(downloading.detail).toBe("2.0 MB/s · 1m 30s left");
    expect(downloading.canCancel).toBe(true);
    expect(downloading.indeterminate).toBe(false);

    const failed = describeJob(job("failed", { error: { code: "video_unavailable", message: "This video is unavailable.", retryable: false } }));
    expect(failed.label).toBe("This video is unavailable.");
    expect(failed.canSave).toBe(false);
    expect(failed.canRetry).toBe(false);
    expect(failed.terminal).toBe(true);

    const completed = describeJob(job("completed", { progress: { percent: 100 }, result: { filename: "a.mp4", size_bytes: 1, download_url: "/x" } }));
    expect(completed.canSave).toBe(true);
    expect(describeJob(job("completed")).canSave).toBe(false); // completed without a result is not savable
  });

  it("offers retry after cancel, interruption and retryable failures", () => {
    expect(describeJob(job("cancelled")).canRetry).toBe(true);
    expect(describeJob(job("interrupted")).canRetry).toBe(true);
    expect(describeJob(job("failed", { error: { code: "network_transient", message: "m", retryable: true } })).canRetry).toBe(true);
  });

  it("labels automatic retries", () => {
    expect(describeJob(job("queued", { attempt: 1, max_attempts: 3 })).label).toBe("Retrying (attempt 2 of 3)…");
    expect(isTerminal("queued")).toBe(false);
    expect(isTerminal("interrupted")).toBe(true);
  });

  it("formats sizes", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(null)).toBeNull();
    expect(formatBytes(-5)).toBeNull();
  });

  it("builds safe local names and mime types", () => {
    const name = safeLocalName("../../etc/pass:wd*?.mp4", "AbC-123_xyz789");
    expect(name).not.toMatch(/[\\/:*?"<>|]/);
    expect(name.startsWith("AbC123xy-")).toBe(true);
    expect(safeLocalName("", "id")).toBe("id-video");
    expect(safeLocalName("....", "id")).toBe("id-video");
    expect(mimeFor("a.MP4")).toBe("video/mp4");
    expect(mimeFor("a.mp3")).toBe("audio/mpeg");
    expect(mimeFor("a.bin")).toBe("application/octet-stream");
  });
});

describe("watchJob", () => {
  function manualScheduler() {
    const queue: (() => void)[] = [];
    return {
      schedule: (cb: () => void) => queue.push(cb),
      cancelSchedule: () => undefined,
      run: async () => {
        const next = queue.shift();
        if (next) next();
        await tick();
      },
      pending: () => queue.length,
    };
  }
  const flush = tick;

  it("reports every state and stops after the terminal one", async () => {
    const states = [job("queued"), job("downloading", { progress: { percent: 10 } }), job("completed")];
    let calls = 0;
    const api = { getJob: async () => states[Math.min(calls++, 2)] } as never;
    const scheduler = manualScheduler();
    const seen: string[] = [];
    watchJob(api, "id", (j) => seen.push(j.status), scheduler);
    await flush();
    await scheduler.run();
    await scheduler.run();
    expect(seen).toEqual(["queued", "downloading", "completed"]);
    expect(scheduler.pending()).toBe(0);
  });

  it("retries transient errors quietly, then fails on 404", async () => {
    let calls = 0;
    const api = {
      getJob: async () => {
        calls += 1;
        throw calls === 1 ? new Error("network down") : new ApiRequestError("Not found.", 404, "not_found", false);
      },
    } as never;
    const scheduler = manualScheduler();
    const seen: JobResponse[] = [];
    watchJob(api, "gone", (j) => seen.push(j), scheduler);
    await flush();
    expect(seen).toHaveLength(0);
    await scheduler.run();
    expect(seen).toHaveLength(1);
    expect(seen[0].status).toBe("failed");
    expect(seen[0].error?.message).toBe("Not found.");
  });

  it("gives up after repeated network failures and stop() silences it", async () => {
    const api = { getJob: async () => { throw new Error("offline"); } } as never;
    const scheduler = manualScheduler();
    const seen: JobResponse[] = [];
    const watcher = watchJob(api, "x", (j) => seen.push(j), { ...scheduler, maxConsecutiveFailures: 2 });
    await flush();
    await scheduler.run();
    expect(seen).toHaveLength(1);
    expect(seen[0].error?.retryable).toBe(true);

    const quiet = { getJob: async () => job("downloading") } as never;
    const sched2 = manualScheduler();
    const seen2: JobResponse[] = [];
    const w2 = watchJob(quiet, "y", (j) => seen2.push(j), sched2);
    w2.stop();
    await flush();
    await sched2.run();
    expect(seen2).toEqual([]);
    watcher.stop();
  });
});
