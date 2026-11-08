import path from "node:path";

/**
 * Makes a user-supplied file name safe to join under an attachment directory.
 * Keeps CJK characters, strips separators and control characters.
 */
export function sanitizeFileName(name: string): string {
  const base = path
    .basename(name)
    .replace(/[^\w.\- 一-鿿]/g, "_")
    .trim()
    .slice(0, 200);
  return base.length > 0 ? base : "file";
}
