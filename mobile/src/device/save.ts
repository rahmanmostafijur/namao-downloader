/**
 * Getting a finished file from the server onto the phone.
 *
 * The server keeps working whether or not the app is open; only this last hop runs on the
 * device. iOS can continue the transfer in a background session (`sessionType: 'background'`),
 * but if the app is killed the JS side of the task is gone, so the user taps Save again (the
 * server file is still there until it expires). Android ignores the option and the transfer may
 * stop when the system suspends the app.
 */
import { File, Paths } from "expo-file-system";
import * as MediaLibrary from "expo-media-library";
import * as Sharing from "expo-sharing";

import type { Api, JobResponse } from "../core/api";
import { mimeFor, safeLocalName } from "../core/jobs";

export type TransferProgress = (bytesWritten: number, totalBytes: number) => void;

export async function downloadFinishedFile(
  api: Api,
  job: JobResponse,
  onProgress?: TransferProgress,
  signal?: AbortSignal,
): Promise<File> {
  if (!job.result) throw new Error("This download isn't ready yet.");
  const expectedSize = job.result.size_bytes;
  const request = api.fileRequest(job.id);
  const name = safeLocalName(job.result.filename, job.id);

  // A file left by an earlier attempt only counts if it is complete: on Android a failed or
  // interrupted transfer can leave a partial file behind.
  const finalFile = new File(Paths.cache, name);
  if (finalFile.exists) {
    if (finalFile.size === expectedSize) return finalFile;
    discardLocalCopy(finalFile);
  }

  const partial = new File(Paths.cache, `${name}.part`);
  discardLocalCopy(partial);
  try {
    const task = File.createDownloadTask(request.url, partial, {
      headers: request.headers,
      sessionType: "background",
      signal,
      onProgress: (progress) => onProgress?.(progress.bytesWritten, progress.totalBytes),
    });
    const downloaded = await task.downloadAsync();
    if (!downloaded) throw new Error("The transfer was paused before it finished.");
    if (partial.size !== expectedSize) {
      throw new Error("The file didn't transfer completely. Please try again.");
    }
    await partial.move(finalFile); // only a complete file ever gets its final name
    return finalFile;
  } catch (error) {
    discardLocalCopy(partial);
    throw error;
  }
}

/** Save into the device's media library (Photos on iOS, MediaStore on Android). */
export async function saveToLibrary(file: File): Promise<void> {
  const permission = await MediaLibrary.requestPermissionsAsync(true); // write-only access is enough
  if (!permission.granted) {
    throw new Error("Allow access to save to your library, or use Share → Save to Files instead.");
  }
  await MediaLibrary.Asset.create(file.uri);
}

/** Open the system share sheet (on iOS this includes "Save to Files"). */
export async function shareFile(file: File, filename: string): Promise<void> {
  if (!(await Sharing.isAvailableAsync())) throw new Error("Sharing isn't available on this device.");
  await Sharing.shareAsync(file.uri, { mimeType: mimeFor(filename), dialogTitle: "Save or share" });
}

export function discardLocalCopy(file: File): void {
  try {
    file.delete();
  } catch {
    /* already gone */
  }
}
