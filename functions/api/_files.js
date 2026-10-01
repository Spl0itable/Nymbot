import { renderPdf } from "./_filepdf.js";
import { renderDocx, renderXlsx, tablesFromMarkdown, XLSX_MAX_ROWS, XLSX_MAX_COLS } from "./_fileoffice.js";
import { parseMarkdown, looksLikeHtml, htmlToMarkdown, inlineText } from "./_filemd.js";
import { utf8, zipFiles } from "./_filezip.js";

export var FILE_TOOL = "create_file";
export var FILE_MAX_PER_REPLY = 5;
export var FILE_MAX_BYTES = 5 * 1024 * 1024;
export var FILE_MAX_REPLY_BYTES = 15 * 1024 * 1024;
export var FILE_MAX_CHARS = 400000;
export var FILE_MAX_ZIP_ENTRIES = 20;
export var FILE_NAME_MAX = 80;
export var FILE_RECALL_FILES = 3;
export var FILE_RECALL_CHARS = 20000;
export var FILE_RECALL_TOTAL = 40000;

export var FILE_FORMATS = {
  pdf: { ext: "pdf", type: "application/pdf", label: "PDF" },
  docx: { ext: "docx", type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", label: "Word document" },
  xlsx: { ext: "xlsx", type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", label: "Excel spreadsheet" },
  csv: { ext: "csv", type: "text/csv", label: "CSV", text: true },
  md: { ext: "md", type: "text/markdown", label: "Markdown", text: true },
  txt: { ext: "txt", type: "text/plain", label: "Text", text: true },
  html: { ext: "html", type: "text/html", host: "application/octet-stream", label: "HTML", text: true },
  json: { ext: "json", type: "application/json", label: "JSON", text: true },
  zip: { ext: "zip", type: "application/zip", label: "ZIP archive" }
};

var ALIASES = {
  markdown: "md", text: "txt", plain: "txt", htm: "html", word: "docx", doc: "docx",
  excel: "xlsx", xls: "xlsx", spreadsheet: "xlsx", sheet: "xlsx", tsv: "csv", "zip-archive": "zip"
};

var STRIP_EXT = /\.(exe|com|bat|cmd|msi|msp|scr|pif|cpl|jar|js|mjs|jse|vbs|vbe|wsf|wsh|ps1|psm1|sh|bash|zsh|command|app|apk|ipa|dmg|pkg|deb|rpm|dll|so|dylib|lnk|reg|hta|svg|xhtml|htm|html|php|py|rb|pl|pdf|docx?|xlsx?|xlsm|docm|csv|tsv|md|markdown|txt|json|zip|rtf)$/i;
var RESERVED = /^(con|prn|aux|nul|com\d|lpt\d)$/i;

export function fileFormat(raw) {
  var f = String(raw || "").trim().toLowerCase().replace(/^\./, "");
  if (Object.prototype.hasOwnProperty.call(FILE_FORMATS, f)) return f;
  if (Object.prototype.hasOwnProperty.call(ALIASES, f)) return ALIASES[f];
  return "";
}

export function cleanFileName(raw, format) {
  var ext = FILE_FORMATS[format].ext;
  var s = String(raw == null ? "" : raw);
  try { s = s.normalize("NFC"); } catch (e) { }
  s = s.split(/[\\/]/).pop();
  s = s.replace(/[\u0000-\u001f\u007f-\u009f\u00ad\u061c\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]/g, "");
  s = s.replace(/[<>:"|?*\[\]#%{}^`~\\$]/g, "_");
  s = s.replace(/\s+/g, " ").trim();
  var prev;
  do {
    prev = s;
    s = s.replace(/[.\s_-]+$/, "").replace(STRIP_EXT, "");
  } while (s !== prev);
  s = s.replace(/^[.\s_-]+/, "");
  if (!s) s = "file";
  if (RESERVED.test(s.split(".")[0])) s = "_" + s;
  if (s.length > FILE_NAME_MAX) s = s.slice(0, FILE_NAME_MAX).replace(/[.\s_-]+$/, "");
  return s + "." + ext;
}

export function fileToolDef() {
  return {
    type: "function",
    function: {
      name: FILE_TOOL,
      description: "Make a real file and attach it to your reply as a download (PDF, Word, Excel, CSV, Markdown, text, HTML, JSON, or a ZIP of several). " +
        "Use it whenever the user asks for a file or a document, or to put something from the conversation into one. " +
        "pdf and docx take Markdown (headings, lists, tables, bold/italic, code blocks; a line with only \\pagebreak starts a new page). " +
        "xlsx takes Markdown tables (one sheet per table, named after the heading above it), CSV, or a JSON array of rows; simple formulas such as =SUM(B2:B9) are kept. " +
        "The file appears under your reply on its own: do not paste its content or a link to it in the reply.",
      parameters: {
        type: "object",
        properties: {
          filename: { type: "string", description: "File name with its extension, e.g. report.pdf" },
          format: { type: "string", enum: Object.keys(FILE_FORMATS), description: "Defaults to the filename's extension." },
          content: { type: "string", description: "The full content: Markdown for pdf/docx, tables or CSV for xlsx, the text itself for the others. Not used for zip." },
          title: { type: "string", description: "Optional document title for pdf/docx/xlsx metadata." },
          paper: { type: "string", enum: ["letter", "a4"], description: "Page size for pdf/docx; letter by default." },
          files: {
            type: "array",
            description: "For format zip only: the files to put in the archive.",
            items: {
              type: "object",
              properties: {
                filename: { type: "string" },
                format: { type: "string", enum: Object.keys(FILE_FORMATS).filter(function (k) { return k !== "zip"; }) },
                content: { type: "string" }
              },
              required: ["filename", "content"]
            }
          }
        },
        required: ["filename"]
      }
    }
  };
}

export function filePrompt() {
  return [
    "",
    "=== FILES (PDF, WORD, EXCEL AND MORE) ===",
    "You can hand the user real files: pdf, docx, xlsx, csv, md, txt, html, json, or a zip of several. When they ask for a file or a document, or to put something from this conversation into one (\"put that in a PDF\", \"export this table to Excel\"), make it. Never say you cannot send files.",
    "If a " + FILE_TOOL + " tool is offered to you, use it. Otherwise write the file as a fenced block whose info line is nymbot-file with a name, and Nymbot turns the block into the file:",
    "````nymbot-file name=\"report.pdf\" title=\"Quarterly report\"",
    "# Quarterly report",
    "Markdown content of the file...",
    "````",
    "The name's extension picks the format. pdf and docx are written in Markdown: headings, lists, tables, **bold**, *italic*, code blocks, and a line with only \\pagebreak for a new page. xlsx takes Markdown tables (one sheet per table, named after the heading above it) or CSV; simple formulas such as =SUM(B2:B9) are kept. Open the block with four backticks so ``` fences inside it stay in the file. Blocks that share zip=\"bundle.zip\" arrive as one zip.",
    "Put the whole content in the file, never placeholders. Keep your reply around it to a sentence saying what the file is: the file appears under your message as a card, so do not repeat its content and do not write a link to it. At most " + FILE_MAX_PER_REPLY + " files a reply, " + (FILE_MAX_BYTES / 1048576) + " MB each. PDF text covers Latin, Greek and Cyrillic scripts; for Chinese, Japanese, Korean, Arabic, Hebrew, Indic scripts or emoji make a docx, html or md instead, which keep every character.",
    "Files you made earlier in this chat are listed under FILES YOU MADE EARLIER with the source each was built from; to change one, make a new file from that source."
  ].join("\n");
}

export function fileSpec(raw, inZip) {
  var r = raw && typeof raw === "object" ? raw : {};
  var name = typeof r.filename === "string" ? r.filename : typeof r.name === "string" ? r.name : "";
  var extMatch = /\.([A-Za-z0-9]{1,10})\s*$/.exec(name);
  var format = fileFormat(r.format) || (extMatch ? fileFormat(extMatch[1]) : "");
  if (!format) return { ok: false, error: "say which format to make (pdf, docx, xlsx, csv, md, txt, html, json or zip), or give the filename its extension" };
  if (inZip && format === "zip") return { ok: false, error: "a zip cannot contain another zip" };
  var spec = {
    name: cleanFileName(name, format),
    format: format,
    title: typeof r.title === "string" ? r.title.replace(/[\u0000-\u001f]/g, " ").trim().slice(0, 200) : "",
    paper: String(r.paper || "").toLowerCase() === "a4" ? "a4" : "letter"
  };
  if (format === "zip") {
    var list = Array.isArray(r.files) ? r.files : [];
    if (!list.length) return { ok: false, error: "a zip needs files: [{filename, content}]" };
    if (list.length > FILE_MAX_ZIP_ENTRIES) return { ok: false, error: "a zip can hold at most " + FILE_MAX_ZIP_ENTRIES + " files" };
    var entries = [];
    var total = 0;
    var names = {};
    for (var i = 0; i < list.length; i++) {
      var inner = fileSpec(list[i], true);
      if (!inner.ok) return { ok: false, error: "file " + (i + 1) + " of the zip: " + inner.error };
      total += inner.spec.content.length;
      var n = inner.spec.name;
      var k = 2;
      while (names[n.toLowerCase()]) n = inner.spec.name.replace(/(\.[a-z0-9]+)$/, " (" + (k++) + ")$1");
      names[n.toLowerCase()] = true;
      inner.spec.name = n;
      entries.push(inner.spec);
    }
    if (total > FILE_MAX_CHARS) return { ok: false, error: "the zip's files are too long together (" + total + " characters; the limit is " + FILE_MAX_CHARS + ")" };
    spec.files = entries;
    return { ok: true, spec: spec };
  }
  if (typeof r.content !== "string" || !r.content.trim()) return { ok: false, error: "the file has no content" };
  if (r.content.length > FILE_MAX_CHARS) return { ok: false, error: "the content is too long (" + r.content.length + " characters; the limit is " + FILE_MAX_CHARS + ")" };
  spec.content = r.content.replace(/\r\n?/g, "\n");
  return { ok: true, spec: spec };
}

function detectDelimiter(text) {
  var first = String(text).split("\n").slice(0, 5).join("\n");
  var counts = { ",": 0, ";": 0, "\t": 0 };
  var quoted = false;
  for (var i = 0; i < first.length; i++) {
    var c = first.charAt(i);
    if (c === "\"") quoted = !quoted;
    else if (!quoted && Object.prototype.hasOwnProperty.call(counts, c)) counts[c]++;
  }
  if (counts["\t"] > counts[","] && counts["\t"] >= counts[";"]) return "\t";
  if (counts[";"] > counts[","]) return ";";
  return ",";
}

export function parseCsv(text, delimiter) {
  var d = delimiter || detectDelimiter(text);
  var rows = [];
  var row = [];
  var cell = "";
  var quoted = false;
  var s = String(text).replace(/^\ufeff/, "");
  for (var i = 0; i < s.length; i++) {
    var c = s.charAt(i);
    if (quoted) {
      if (c === "\"") {
        if (s.charAt(i + 1) === "\"") { cell += "\""; i++; } else quoted = false;
      } else {
        cell += c;
      }
    } else if (c === "\"" && cell === "") {
      quoted = true;
    } else if (c === d) {
      row.push(cell); cell = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && s.charAt(i + 1) === "\n") i++;
      row.push(cell); cell = "";
      rows.push(row); row = [];
    } else {
      cell += c;
    }
  }
  if (cell !== "" || row.length) { row.push(cell); rows.push(row); }
  return rows.filter(function (r) { return r.length > 1 || (r[0] || "").trim(); });
}

function neutralize(cell) {
  var s = String(cell == null ? "" : cell);
  if (/^[=+\-@\t\r]/.test(s) && !/^[+-]?\d[\d,]*(\.\d+)?([eE][+-]?\d+)?%?$/.test(s.trim())) return "'" + s;
  return s;
}

export function toCsv(rows) {
  return rows.map(function (r) {
    return r.map(function (c) {
      var v = neutralize(c);
      return /[",\n\r]/.test(v) || /^\s|\s$/.test(v) ? "\"" + v.replace(/"/g, "\"\"") + "\"" : v;
    }).join(",");
  }).join("\r\n") + "\r\n";
}

function rowsFromJson(text) {
  var v;
  try { v = JSON.parse(text); } catch (e) { return null; }
  if (!Array.isArray(v) || !v.length) return null;
  if (v.every(function (r) { return Array.isArray(r); })) {
    return v.map(function (r) { return r.map(function (c) { return c == null ? "" : typeof c === "object" ? JSON.stringify(c) : String(c); }); });
  }
  if (v.every(function (r) { return r && typeof r === "object" && !Array.isArray(r); })) {
    var keys = [];
    v.forEach(function (r) { Object.keys(r).forEach(function (k) { if (keys.indexOf(k) === -1) keys.push(k); }); });
    return [keys].concat(v.map(function (r) {
      return keys.map(function (k) { var c = r[k]; return c == null ? "" : typeof c === "object" ? JSON.stringify(c) : String(c); });
    }));
  }
  return null;
}

export function sheetsFrom(content) {
  var tables = tablesFromMarkdown(content);
  if (tables.length) return tables;
  var json = /^\s*\[/.test(content) ? rowsFromJson(content) : null;
  if (json) return [{ name: "Sheet1", rows: json }];
  return [{ name: "Sheet1", rows: parseCsv(content) }];
}

function clip(rows, notes) {
  var out = rows;
  if (out.length > XLSX_MAX_ROWS) {
    notes.push("only the first " + XLSX_MAX_ROWS + " rows were kept");
    out = out.slice(0, XLSX_MAX_ROWS);
  }
  if (out.some(function (r) { return r.length > XLSX_MAX_COLS; })) {
    notes.push("only the first " + XLSX_MAX_COLS + " columns were kept");
    out = out.map(function (r) { return r.slice(0, XLSX_MAX_COLS); });
  }
  return out;
}

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function htmlInlines(list) {
  return (list || []).map(function (s) {
    var t = esc(s.text).replace(/\n/g, "<br>");
    if (s.code) t = "<code>" + t + "</code>";
    if (s.b) t = "<strong>" + t + "</strong>";
    if (s.i) t = "<em>" + t + "</em>";
    if (s.s) t = "<del>" + t + "</del>";
    if (s.href) t = "<a href=\"" + esc(s.href) + "\" rel=\"noopener noreferrer\">" + t + "</a>";
    return t;
  }).join("");
}

function htmlBlocks(blocks) {
  return blocks.map(function (b) {
    if (b.type === "heading") return "<h" + b.level + ">" + htmlInlines(b.inlines) + "</h" + b.level + ">";
    if (b.type === "para") return "<p>" + htmlInlines(b.inlines) + "</p>";
    if (b.type === "code") return "<pre><code>" + esc(b.text) + "</code></pre>";
    if (b.type === "quote") return "<blockquote>" + htmlBlocks(b.blocks) + "</blockquote>";
    if (b.type === "hr") return "<hr>";
    if (b.type === "pagebreak") return "<div style=\"page-break-after: always\"></div>";
    if (b.type === "list") {
      var tag = b.ordered ? "ol" : "ul";
      return "<" + tag + (b.ordered && b.start !== 1 ? " start=\"" + b.start + "\"" : "") + ">" + b.items.map(function (it) {
        var box = it.task === null ? "" : "<input type=\"checkbox\" disabled" + (it.task ? " checked" : "") + "> ";
        return "<li>" + box + htmlBlocks(it.blocks) + "</li>";
      }).join("") + "</" + tag + ">";
    }
    if (b.type === "table") {
      var cell = function (tag, c, i) { return "<" + tag + (b.align[i] !== "left" ? " style=\"text-align:" + b.align[i] + "\"" : "") + ">" + htmlInlines(c) + "</" + tag + ">"; };
      return "<table><thead><tr>" + b.head.map(function (c, i) { return cell("th", c, i); }).join("") + "</tr></thead><tbody>" +
        b.rows.map(function (r) { return "<tr>" + r.map(function (c, i) { return cell("td", c, i); }).join("") + "</tr>"; }).join("") + "</tbody></table>";
    }
    return "";
  }).join("\n");
}

export function markdownToHtml(markdown, title) {
  var blocks = parseMarkdown(markdown);
  var heading = "";
  for (var i = 0; i < blocks.length && !heading; i++) if (blocks[i].type === "heading") heading = inlineText(blocks[i].inlines);
  return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>" + esc(title || heading || "Document") + "</title>\n" +
    "<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;line-height:1.55;max-width:46rem;margin:2rem auto;padding:0 1rem;color:#222}" +
    "pre{background:#f3f3f5;padding:.8rem;overflow:auto;border-radius:6px}code{font-family:ui-monospace,Menlo,Consolas,monospace}" +
    "table{border-collapse:collapse}th,td{border:1px solid #ccc;padding:.3rem .6rem}th{background:#eef0f4}blockquote{border-left:3px solid #ccc;margin-left:0;padding-left:1rem;color:#555}</style>\n</head>\n<body>\n" +
    htmlBlocks(blocks) + "\n</body>\n</html>\n";
}

function asMarkdown(content) {
  return looksLikeHtml(content) ? htmlToMarkdown(content) : content;
}

export async function renderFileSpec(spec) {
  var notes = [];
  var bytes;
  var pages = 0;
  if (spec.format === "pdf") {
    var made = await renderPdf(asMarkdown(spec.content), { title: spec.title, paper: spec.paper });
    bytes = made.bytes;
    pages = made.pages;
    if (made.missing) notes.push(made.missing + " character" + (made.missing === 1 ? "" : "s") + " (such as " + JSON.stringify(made.missingSample.slice(0, 6)) + ") are outside the PDF font and show as ?; a docx, html or md file keeps them");
    if (made.truncated) notes.push("the PDF was cut at " + made.pages + " pages or a table row was too tall for a page");
  } else if (spec.format === "docx") {
    bytes = await renderDocx(asMarkdown(spec.content), { title: spec.title, paper: spec.paper });
  } else if (spec.format === "xlsx") {
    var sheets = sheetsFrom(spec.content).map(function (s) { return { name: s.name, rows: clip(s.rows, notes) }; });
    if (!sheets.some(function (s) { return s.rows.length; })) throw new Error("no table or CSV rows were found in the content");
    bytes = await renderXlsx(sheets, { title: spec.title });
  } else if (spec.format === "csv") {
    var tables = tablesFromMarkdown(spec.content);
    var rows = tables.length ? tables[0].rows : (/^\s*\[/.test(spec.content) && rowsFromJson(spec.content)) || parseCsv(spec.content);
    if (!rows.length) throw new Error("no rows were found in the content");
    bytes = utf8("\ufeff" + toCsv(rows));
  } else if (spec.format === "json") {
    var parsed;
    try { parsed = JSON.parse(spec.content); } catch (e) { throw new Error("the content is not valid JSON (" + String(e && e.message || e).slice(0, 120) + ")"); }
    bytes = utf8(JSON.stringify(parsed, null, 2) + "\n");
  } else if (spec.format === "html") {
    var html = looksLikeHtml(spec.content) ? spec.content : markdownToHtml(spec.content, spec.title);
    if (!/<meta[^>]+charset/i.test(html)) html = html.replace(/<head[^>]*>/i, function (m) { return m + "\n<meta charset=\"utf-8\">"; });
    if (!/^\s*<!doctype/i.test(html)) html = "<!doctype html>\n" + html;
    bytes = utf8(html);
  } else if (spec.format === "zip") {
    var entries = [];
    for (var i = 0; i < spec.files.length; i++) {
      var inner = await renderFileSpec(spec.files[i]);
      inner.notes.forEach(function (n) { notes.push(spec.files[i].name + ": " + n); });
      entries.push({ name: spec.files[i].name, data: inner.bytes });
    }
    bytes = await zipFiles(entries);
  } else {
    var text = spec.content.replace(/\s+$/, "") + "\n";
    bytes = utf8(text);
  }
  if (bytes.length > FILE_MAX_BYTES) throw new Error("the file came to " + Math.round(bytes.length / 1048576 * 10) / 10 + " MB, over the " + (FILE_MAX_BYTES / 1048576) + " MB limit; split it into smaller files");
  return { bytes: bytes, notes: notes, pages: pages };
}

export function fileSize(n) {
  var v = Number(n) || 0;
  if (v < 1024) return v + " B";
  if (v < 1048576) return Math.round(v / 1024) + " KB";
  return (Math.round(v / 1048576 * 10) / 10) + " MB";
}

function fragEncode(s) {
  return encodeURIComponent(String(s)).replace(/[!'()*]/g, function (c) { return "%" + c.charCodeAt(0).toString(16).toUpperCase(); });
}

export function fileLine(file) {
  var frag = "#nymbot-file&name=" + fragEncode(file.name) + "&type=" + fragEncode(file.type) + "&size=" + (Number(file.size) || 0) +
    (file.src ? "&src=" + fragEncode(file.src) : "");
  return "[" + file.name + "](" + file.url + frag + ")";
}

var LINK_RE = /\[([^\]\n]{1,200})\]\((https:\/\/[^\s)#]+)#nymbot-file&([^\s)]*)\)/g;

export function fileLinksIn(text) {
  var out = [];
  var re = new RegExp(LINK_RE.source, "g");
  var m;
  while ((m = re.exec(String(text || "")))) {
    var params = {};
    m[3].split("&").forEach(function (kv) {
      var at = kv.indexOf("=");
      if (at <= 0) return;
      try { params[kv.slice(0, at)] = decodeURIComponent(kv.slice(at + 1)); } catch (e) { }
    });
    out.push({ label: m[1], url: m[2], name: params.name || m[1], type: params.type || "", size: Number(params.size) || 0, src: params.src || "" });
  }
  return out;
}

function hostedUrl(url, format) {
  if (format === "html") return url;
  var u;
  try { u = new URL(url); } catch (e) { return url; }
  var tail = u.pathname.split("/").pop();
  if (!tail || tail.indexOf(".") !== -1 || u.search || u.hash) return url;
  u.pathname += "." + FILE_FORMATS[format].ext;
  return u.toString();
}

function sourceOf(spec) {
  if (spec.format === "zip") {
    return spec.files.map(function (f) { return "--- " + f.name + " ---\n" + f.content; }).join("\n\n");
  }
  return spec.content;
}

var OPEN_RE = /^( {0,3})(`{3,}|~{3,})[ \t]*nymbot-file\b(.*)$/i;
var BARE_FENCE = /^ {0,3}(`{3,}|~{3,})\s*$/;
var INFO_FENCE = /^ {0,3}(`{3,}|~{3,})\s*\S/;

function attrs(s) {
  var out = {};
  var re = /([A-Za-z_][\w-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"']+))/g;
  var m;
  while ((m = re.exec(String(s || "")))) out[m[1].toLowerCase()] = m[2] != null ? m[2] : m[3] != null ? m[3] : m[4];
  return out;
}

export function fileBlocks(text) {
  var lines = String(text || "").split("\n");
  var blocks = [];
  var kept = [];
  for (var i = 0; i < lines.length; i++) {
    var open = OPEN_RE.exec(lines[i]);
    if (!open) { kept.push(lines[i]); continue; }
    var mark = open[2];
    var a = attrs(open[3]);
    var body = [];
    var depth = 0;
    var closed = false;
    var j = i + 1;
    for (; j < lines.length; j++) {
      var line = lines[j];
      var bare = BARE_FENCE.exec(line);
      if (bare && bare[1].charAt(0) === mark.charAt(0) && bare[1].length >= mark.length) {
        if (depth > 0 && bare[1].length === mark.length && mark.length === 3) { depth--; body.push(line); continue; }
        closed = true;
        break;
      }
      var info = INFO_FENCE.exec(line);
      if (info && mark.length === 3 && info[1].charAt(0) === mark.charAt(0) && info[1].length === 3) depth++;
      else if (bare && bare[1].charAt(0) === mark.charAt(0) && bare[1].length < mark.length) { body.push(line); continue; }
      body.push(line);
    }
    var lead = open[1].length;
    var content = body.map(function (l) { return lead ? l.replace(new RegExp("^ {0," + lead + "}"), "") : l; }).join("\n");
    blocks.push({
      raw: { filename: a.name || a.filename || "", format: a.format || a.type || "", title: a.title || "", paper: a.paper || "", content: content },
      zip: a.zip || "",
      closed: closed
    });
    kept.push("\u0000FILE" + (blocks.length - 1) + "\u0000");
    i = closed ? j : lines.length;
  }
  return { text: kept.join("\n"), blocks: blocks };
}

export function fileSession(o) {
  var opts = o || {};
  var upload = opts.upload;
  var made = [];
  var pending = [];
  var bytesSoFar = 0;
  var count = 0;

  async function host(spec) {
    if (count >= FILE_MAX_PER_REPLY) throw new Error("this reply already has " + FILE_MAX_PER_REPLY + " files, the most one reply can carry");
    count++;
    var rendered;
    try {
      rendered = await renderFileSpec(spec);
    } catch (e) {
      count--;
      throw e;
    }
    if (bytesSoFar + rendered.bytes.length > FILE_MAX_REPLY_BYTES) {
      count--;
      throw new Error("the files in this reply would pass " + (FILE_MAX_REPLY_BYTES / 1048576) + " MB together");
    }
    if (typeof upload !== "function") throw new Error("file hosting is not available on this server");
    var info = FILE_FORMATS[spec.format];
    var url;
    try {
      url = await upload(rendered.bytes, info.host || info.type);
    } catch (e) {
      count--;
      throw new Error("the file was made but could not be stored for delivery: " + String((e && e.message) || e).slice(0, 160));
    }
    if (typeof url !== "string" || !/^https:\/\//.test(url)) {
      count--;
      throw new Error("the file was made but could not be stored for delivery");
    }
    bytesSoFar += rendered.bytes.length;
    var src = "";
    if (!info.text) {
      try {
        var s = await upload(utf8(sourceOf(spec)), "text/plain");
        if (typeof s === "string" && /^https:\/\//.test(s)) src = s;
      } catch (e) { }
    }
    var file = {
      name: spec.name, format: spec.format, type: info.type, label: info.label,
      size: rendered.bytes.length, pages: rendered.pages, url: hostedUrl(url, spec.format), src: src, notes: rendered.notes
    };
    made.push(file);
    if (typeof opts.progress === "function") {
      try { opts.progress({ kind: "file", name: file.name, size: file.size, format: file.format }); } catch (e) { }
    }
    return file;
  }

  function describe(file) {
    return "Created " + file.name + " (" + file.label + (file.pages ? ", " + file.pages + " page" + (file.pages === 1 ? "" : "s") : "") + ", " + fileSize(file.size) + ")." +
      (file.notes.length ? " Note: " + file.notes.join("; ") + "." : "");
  }

  return {
    tool: fileToolDef(),
    name: FILE_TOOL,
    exec: async function (args) {
      var checked = fileSpec(args);
      if (!checked.ok) return "Error: " + checked.error + ". Nothing was made.";
      try {
        var file = await host(checked.spec);
        pending.push(file);
        return describe(file) + " It is attached under your reply as a download card, so do not paste its content or a link to it; just mention it by name.";
      } catch (e) {
        return "Error: " + String((e && e.message) || e).slice(0, 300) + ". Nothing was attached.";
      }
    },
    deliver: async function (text) {
      var full = String(text == null ? "" : text);
      var think = /^\s*<think>[\s\S]*?<\/think>\s*/i.exec(full);
      var head = think ? think[0] : "";
      var parsed = fileBlocks(full.slice(head.length));
      var outs = [];
      var zips = {};
      for (var b = 0; b < parsed.blocks.length; b++) {
        var blk = parsed.blocks[b];
        if (blk.zip) {
          var zkey = cleanFileName(blk.zip, "zip").toLowerCase();
          if (!zips[zkey]) zips[zkey] = { name: cleanFileName(blk.zip, "zip"), files: [], first: b };
          zips[zkey].files.push(blk.raw);
          outs[b] = zips[zkey].first === b ? { zip: zkey } : { text: "" };
          continue;
        }
        var checked = fileSpec(blk.raw);
        if (!checked.ok) { outs[b] = { text: "_" + (blk.raw.filename || "A file") + " could not be made: " + checked.error + "._" }; continue; }
        try {
          var f = await host(checked.spec);
          outs[b] = { text: fileLine(f) + (blk.closed ? "" : "\n\n_The reply was cut off, so " + f.name + " may be incomplete._") };
        } catch (e) {
          outs[b] = { text: "_" + checked.spec.name + " could not be made: " + String((e && e.message) || e).slice(0, 200) + "._" };
        }
      }
      var zkeys = Object.keys(zips);
      for (var z = 0; z < zkeys.length; z++) {
        var zip = zips[zkeys[z]];
        var zc = fileSpec({ filename: zip.name, format: "zip", files: zip.files });
        var zt;
        if (!zc.ok) {
          zt = "_" + zip.name + " could not be made: " + zc.error + "._";
        } else {
          try { zt = fileLine(await host(zc.spec)); } catch (e) { zt = "_" + zip.name + " could not be made: " + String((e && e.message) || e).slice(0, 200) + "._"; }
        }
        outs[zip.first] = { text: zt };
      }
      var body = parsed.text.replace(/\u0000FILE(\d+)\u0000/g, function (m, n) {
        var got = outs[Number(n)];
        return got && got.text ? "\n\n" + got.text + "\n\n" : "";
      });
      var tail = pending.splice(0).map(fileLine);
      if (tail.length) body = body.replace(/\s+$/, "") + (body.trim() ? "\n\n" : "") + tail.join("\n\n");
      body = body.replace(/[ \t]+\n\n/g, "\n\n").replace(/\n{3,}/g, "\n\n").replace(/^\n+/, "").replace(/\n+$/, "");
      return head + body;
    },
    made: function () { return made.slice(); }
  };
}

function hexOf(buf) {
  var b = new Uint8Array(buf);
  var s = "";
  for (var i = 0; i < b.length; i++) s += (b[i] < 16 ? "0" : "") + b[i].toString(16);
  return s;
}

function recallUrlOk(url, hosts) {
  var u;
  try { u = new URL(url); } catch (e) { return ""; }
  if (u.protocol !== "https:" || u.username || u.password || u.port) return "";
  if (hosts && hosts.length && hosts.indexOf(u.hostname.toLowerCase()) === -1) return "";
  var m = /^\/([0-9a-f]{64})(\.[a-z0-9]{1,8})?$/.exec(u.pathname);
  return m ? m[1] : "";
}

export async function fileRecallBlock(turns, fetcher, opts) {
  var o = opts || {};
  var seen = {};
  var picked = [];
  for (var t = (turns || []).length - 1; t >= 0 && picked.length < FILE_RECALL_FILES; t--) {
    var turn = turns[t];
    if (!turn || !turn.isBot) continue;
    var links = fileLinksIn(turn.text);
    for (var l = links.length - 1; l >= 0 && picked.length < FILE_RECALL_FILES; l--) {
      var f = links[l];
      if (seen[f.url]) continue;
      seen[f.url] = true;
      var textual = /^(text\/|application\/json)/.test(f.type);
      var from = f.src || (textual ? f.url : "");
      var hash = from ? recallUrlOk(from, o.hosts) : "";
      picked.unshift({ file: f, from: hash ? from : "", hash: hash });
    }
  }
  if (!picked.length) return "";
  var budget = FILE_RECALL_TOTAL;
  var got = await Promise.all(picked.map(async function (p) {
    if (!p.from) return null;
    try {
      var bytes = await fetcher(p.from);
      if (!bytes || !bytes.length) return null;
      var digest = hexOf(await crypto.subtle.digest("SHA-256", bytes));
      if (digest !== p.hash) return null;
      return new TextDecoder("utf-8").decode(bytes);
    } catch (e) {
      return null;
    }
  }));
  var parts = ["FILES YOU MADE EARLIER IN THIS CHAT (the newest last; each with the source it was built from):"];
  picked.forEach(function (p, i) {
    var label = (FILE_FORMATS[fileFormat((/\.([a-z0-9]+)$/i.exec(p.file.name) || [])[1])] || {}).label || p.file.type || "file";
    parts.push("--- " + p.file.name + " (" + label + ", " + fileSize(p.file.size) + ") ---");
    var text = got[i];
    if (text == null) {
      parts.push("[its source could not be loaded; rebuild it from the conversation if it needs changing]");
      return;
    }
    var cap = Math.max(0, Math.min(FILE_RECALL_CHARS, budget));
    var shown = text.length > cap ? text.slice(0, cap) + "\n[... the rest of this source was cut]" : text;
    budget -= Math.min(text.length, cap);
    parts.push(shown);
  });
  parts.push("--- end of files ---");
  return parts.join("\n");
}

export var ARTIFACT_FORMATS = { pdf: true, docx: true };

export function artifactMarkdown(body, lang, title) {
  var text = String(body == null ? "" : body).replace(/\r\n?/g, "\n");
  var l = String(lang || "").trim().toLowerCase();
  var head = title ? "# " + String(title).replace(/\s+/g, " ").trim() + "\n\n" : "";
  if (!l || l === "md" || l === "markdown" || l === "text" || l === "txt" || l === "plaintext") {
    return /^\s*#\s/.test(text) || !head ? text : head + text;
  }
  if ((l === "html" || l === "htm") && looksLikeHtml(text)) return htmlToMarkdown(text);
  if (l === "csv" || l === "tsv") {
    var rows = parseCsv(text, l === "tsv" ? "\t" : "");
    if (rows.length) {
      var width = rows.reduce(function (w, r) { return Math.max(w, r.length); }, 0);
      var cell = function (c) { return String(c == null ? "" : c).replace(/\|/g, "\\|").replace(/\n/g, " "); };
      var line = function (r) { var full = r.slice(); while (full.length < width) full.push(""); return "| " + full.map(cell).join(" | ") + " |"; };
      return head + [line(rows[0]), "|" + new Array(width).fill("---").join("|") + "|"].concat(rows.slice(1).map(line)).join("\n");
    }
  }
  var longest = 2;
  (text.match(/`+/g) || []).forEach(function (run) { if (run.length > longest) longest = run.length; });
  var fence = new Array(longest + 2).join("`");
  return head + fence + l.replace(/[^\w+#.-]/g, "") + "\n" + text + "\n" + fence;
}

export async function renderArtifact(o) {
  var format = String(o && o.format || "").toLowerCase();
  if (!ARTIFACT_FORMATS[format]) return { ok: false, error: "only pdf and docx are offered for artifacts" };
  var body = String(o && o.body || "");
  if (!body.trim()) return { ok: false, error: "the artifact is empty" };
  if (body.length > FILE_MAX_CHARS) return { ok: false, error: "the artifact is too long to convert (" + body.length + " characters; the limit is " + FILE_MAX_CHARS + ")" };
  var title = String(o && o.title || "").replace(/[\u0000-\u001f]/g, " ").trim().slice(0, 200);
  var checked = fileSpec({ filename: title || "artifact", format: format, title: title, content: artifactMarkdown(body, o && o.lang, title) });
  if (!checked.ok) return { ok: false, error: checked.error };
  try {
    var made = await renderFileSpec(checked.spec);
    return { ok: true, name: checked.spec.name, type: FILE_FORMATS[format].type, bytes: made.bytes, notes: made.notes };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e).slice(0, 300) };
  }
}
