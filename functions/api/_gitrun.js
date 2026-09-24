export var GIT_READ_CHUNK_LINES = 400;
export var GIT_READ_MAX_CHARS = 48000;
export var GIT_TRIM_MIN_CHARS = 600;
export var GIT_TRIM_KEEP_STEPS = 2;
export var GIT_SEARCH_MAX_MATCHES = 30;
export var GIT_SEARCH_MAX_CHARS = 9000;
export var GIT_SEARCH_PER_FILE = 5;
export var GIT_SEARCH_CONTEXT = 2;
export var GIT_ARCHIVE_DEFAULT_MB = 20;
export var GIT_ARCHIVE_MAX_FILE_BYTES = 1024 * 1024;
export var GIT_ARCHIVE_MAX_TOTAL_BYTES = 48 * 1024 * 1024;
export var GIT_STAGE_MAX_FILES = 60;
export var GIT_STAGE_MAX_BYTES = 2 * 1024 * 1024;
export var GIT_DIFF_MAX_CHARS = 200000;
export var GIT_DIFF_MAX_LCS = 4000000;

var TRIM_MARK = "[trimmed: ";

function str(v) { return v == null ? "" : String(v); }

function gitArgsOf(call) {
  var raw = call && call.function && call.function.arguments;
  if (raw && typeof raw === "object") return raw;
  try { return JSON.parse(raw || "{}") || {}; } catch (e) { return {}; }
}

function gitReadKey(name, args) {
  if (name === "read_file") {
    return "read|" + str(args.repo) + "|" + str(args.path) + "|" +
      str(args.start_line || "") + "-" + str(args.end_line || "");
  }
  if (name === "list_files") return "list|" + str(args.repo) + "|" + str(args.path);
  if (name === "search_code") return "search|" + str(args.repo) + "|" + str(args.query);
  return null;
}

function gitTrimLabel(name, args) {
  if (name === "read_file") {
    var range = args.start_line || args.end_line
      ? " lines " + (args.start_line || 1) + "-" + (args.end_line || "end")
      : "";
    return "read_file " + str(args.path) + range;
  }
  if (name === "list_files") return "list_files " + (str(args.path) || "/");
  if (name === "search_code") return "search_code \"" + str(args.query).slice(0, 80) + "\"";
  if (name === "explore") return "explore \"" + str(args.question).slice(0, 80) + "\"";
  if (name === "ci_status") return "ci_status " + str(args.ref);
  return str(name || "tool");
}

export function gitTrimStub(name, args, content) {
  var size = str(content).length;
  return TRIM_MARK + gitTrimLabel(name, args || {}) + " — " + size +
    " chars, already seen above. Call it again if you need it.]";
}

function gitShrinkArgs(name, args) {
  var out = Object.assign({}, args);
  var changed = false;
  if (typeof out.content === "string" && out.content.length > GIT_TRIM_MIN_CHARS) {
    out.content = "[" + out.content.length + " chars omitted]";
    changed = true;
  }
  if (Array.isArray(out.edits)) {
    var total = 0;
    out.edits.forEach(function (e) { total += str(e && e.old).length + str(e && e.new).length; });
    if (total > GIT_TRIM_MIN_CHARS) {
      out.edits = "[" + out.edits.length + " edits, " + total + " chars omitted]";
      changed = true;
    }
  }
  if (typeof out.body === "string" && out.body.length > GIT_TRIM_MIN_CHARS) {
    out.body = out.body.slice(0, 200) + " [trimmed]";
    changed = true;
  }
  return changed ? out : null;
}

export function gitCompactConvo(convo, options) {
  var opts = options || {};
  var keep = Math.max(1, Math.floor(Number(opts.keepSteps) || GIT_TRIM_KEEP_STEPS));
  var minChars = Number(opts.minChars) > 0 ? Number(opts.minChars) : GIT_TRIM_MIN_CHARS;
  var list = Array.isArray(convo) ? convo : [];
  var steps = [];
  var calls = {};
  for (var i = 0; i < list.length; i++) {
    var m = list[i];
    if (m && m.role === "assistant" && Array.isArray(m.tool_calls) && m.tool_calls.length) {
      steps.push(i);
      for (var c = 0; c < m.tool_calls.length; c++) {
        var tc = m.tool_calls[c];
        if (!tc || tc.id == null) continue;
        calls[tc.id] = { name: tc.function && tc.function.name, args: gitArgsOf(tc) };
      }
    }
  }
  if (!steps.length) return list.slice();
  var current = steps[steps.length - 1];
  var cutoff = steps.length > keep ? steps[steps.length - keep] : -1;
  var lastRead = {};
  var editedAt = {};
  for (var j = 0; j < list.length; j++) {
    var t = list[j];
    if (!t || t.role !== "tool") continue;
    var info = calls[t.tool_call_id];
    if (!info) continue;
    var key = gitReadKey(info.name, info.args);
    if (key) lastRead[key] = j;
    if ((info.name === "write_file" || info.name === "edit_file") && info.args.path) {
      editedAt[str(info.args.repo) + "|" + str(info.args.path)] = j;
    }
  }
  return list.map(function (msg, idx) {
    if (!msg) return msg;
    if (msg.role === "tool") {
      if (idx > current) return msg;
      var body = str(msg.content);
      if (body.length <= minChars || body.indexOf(TRIM_MARK) === 0) return msg;
      var about = calls[msg.tool_call_id];
      var name = about ? about.name : "";
      var args = about ? about.args : {};
      var k = about ? gitReadKey(name, args) : null;
      var old = idx < cutoff;
      var superseded = k != null && lastRead[k] > idx;
      var stale = name === "read_file" &&
        editedAt[str(args.repo) + "|" + str(args.path)] > idx;
      if (!old && !superseded && !stale) return msg;
      return Object.assign({}, msg, { content: gitTrimStub(name, args, body) });
    }
    if (msg.role === "assistant" && idx < cutoff && Array.isArray(msg.tool_calls) && msg.tool_calls.length) {
      var touched = false;
      var next = msg.tool_calls.map(function (tc) {
        var name = tc && tc.function && tc.function.name;
        var small = gitShrinkArgs(name, gitArgsOf(tc));
        if (!small) return tc;
        touched = true;
        return Object.assign({}, tc, {
          function: Object.assign({}, tc.function, { arguments: JSON.stringify(small) })
        });
      });
      return touched ? Object.assign({}, msg, { tool_calls: next }) : msg;
    }
    return msg;
  });
}

function gitLinesOf(content) {
  var text = str(content);
  if (!text) return [];
  var lines = text.split("\n");
  if (lines.length && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

function gitLineNo(n, width) {
  var s = String(n);
  while (s.length < width) s = " " + s;
  return s;
}

export function gitReadRange(path, content, startLine, endLine, options) {
  var opts = options || {};
  var chunk = Number(opts.chunkLines) > 0 ? Number(opts.chunkLines) : GIT_READ_CHUNK_LINES;
  var maxChars = Number(opts.maxChars) > 0 ? Number(opts.maxChars) : GIT_READ_MAX_CHARS;
  var lines = gitLinesOf(content);
  var total = lines.length;
  if (!total) return path + " — empty file (0 lines).";
  var hasStart = Number(startLine) > 0;
  var hasEnd = Number(endLine) > 0;
  var ranged = hasStart || hasEnd;
  var s = hasStart ? Math.floor(Number(startLine)) : 1;
  if (s > total) {
    return "Error: start_line " + s + " is past the end of " + path + ", which has " + total + " lines.";
  }
  var e = hasEnd ? Math.min(total, Math.floor(Number(endLine))) : total;
  if (e < s) e = s;
  if (!ranged && (total > chunk || str(content).length > maxChars)) e = Math.min(total, chunk);
  var width = String(e).length;
  var out = [];
  var used = 0;
  var last = s - 1;
  for (var n = s; n <= e; n++) {
    var row = gitLineNo(n, width) + "\t" + lines[n - 1];
    if (used + row.length + 1 > maxChars && out.length) break;
    out.push(row);
    used += row.length + 1;
    last = n;
  }
  var whole = s === 1 && last === total;
  var head = whole
    ? path + " — all " + total + " lines"
    : path + " — lines " + s + "-" + last + " of " + total;
  var tail = "";
  if (last < total) {
    tail = "\n[" + (total - last) + " more lines not shown. Call read_file with start_line=" +
      (last + 1) + " and an end_line to read on.]";
  }
  return head + " (line numbers are not part of the file):\n" + out.join("\n") + tail;
}

export function gitApplyEdits(content, edits, path) {
  var where = path ? " in " + path : "";
  if (!Array.isArray(edits) || !edits.length) {
    return { error: "Error: edits must be a non-empty list of {old, new} replacements." };
  }
  var out = str(content);
  var crlf = out.indexOf("\r\n") !== -1;
  for (var i = 0; i < edits.length; i++) {
    var e = edits[i] || {};
    var old = e.old == null ? "" : String(e.old);
    var rep = e["new"] == null ? "" : String(e["new"]);
    if (!old) {
      return { error: "Error: edit " + (i + 1) + " has an empty `old`. To create a file use write_file." };
    }
    if (crlf && old.indexOf("\r\n") === -1 && out.indexOf(old) === -1) {
      old = old.replace(/\n/g, "\r\n");
      rep = rep.replace(/\r?\n/g, "\r\n");
    }
    var at = out.indexOf(old);
    if (at === -1) {
      return {
        error: "Error: edit " + (i + 1) + ": the `old` text was not found" + where +
          ". Read the lines again and copy them exactly, without the line numbers. No edits were applied."
      };
    }
    var count = 0;
    for (var p = out.indexOf(old); p !== -1; p = out.indexOf(old, p + 1)) {
      count++;
      if (count > 1) break;
    }
    if (count > 1) {
      return {
        error: "Error: edit " + (i + 1) + ": the `old` text appears more than once" + where +
          ". Include more surrounding lines so it matches exactly one place. No edits were applied."
      };
    }
    out = out.slice(0, at) + rep + out.slice(at + old.length);
  }
  return { content: out, applied: edits.length };
}

export function gitTextHash(text) {
  if (text == null) return null;
  var s = String(text);
  var h = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return ("00000000" + h.toString(16)).slice(-8) + ":" + s.length;
}

function gitDiffOps(a, b) {
  var start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  var endA = a.length;
  var endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA--; endB--; }
  var ops = [];
  for (var i = 0; i < start; i++) ops.push([" ", a[i]]);
  var midA = a.slice(start, endA);
  var midB = b.slice(start, endB);
  if (midA.length * midB.length > GIT_DIFF_MAX_LCS) {
    midA.forEach(function (l) { ops.push(["-", l]); });
    midB.forEach(function (l) { ops.push(["+", l]); });
  } else {
    var n = midA.length;
    var m = midB.length;
    var dp = new Array(n + 1);
    for (var x = 0; x <= n; x++) dp[x] = new Uint32Array(m + 1);
    for (var p = n - 1; p >= 0; p--) {
      for (var q = m - 1; q >= 0; q--) {
        dp[p][q] = midA[p] === midB[q] ? dp[p + 1][q + 1] + 1
          : (dp[p + 1][q] >= dp[p][q + 1] ? dp[p + 1][q] : dp[p][q + 1]);
      }
    }
    var ia = 0;
    var ib = 0;
    while (ia < n && ib < m) {
      if (midA[ia] === midB[ib]) { ops.push([" ", midA[ia]]); ia++; ib++; }
      else if (dp[ia + 1][ib] >= dp[ia][ib + 1]) { ops.push(["-", midA[ia]]); ia++; }
      else { ops.push(["+", midB[ib]]); ib++; }
    }
    while (ia < n) ops.push(["-", midA[ia++]]);
    while (ib < m) ops.push(["+", midB[ib++]]);
  }
  for (var k = endA; k < a.length; k++) ops.push([" ", a[k]]);
  return ops;
}

export function gitUnifiedDiff(path, before, after, context) {
  var ctx = context == null ? 3 : context;
  var a = before == null ? [] : gitLinesOf(before);
  var b = after == null ? [] : gitLinesOf(after);
  var head = ["diff --git a/" + path + " b/" + path];
  if (before == null) head.push("new file mode 100644");
  if (after == null) head.push("deleted file mode 100644");
  head.push("--- " + (before == null ? "/dev/null" : "a/" + path));
  head.push("+++ " + (after == null ? "/dev/null" : "b/" + path));
  var ops = gitDiffOps(a, b);
  var oldNo = [];
  var newNo = [];
  var o = 1;
  var nn = 1;
  for (var i = 0; i < ops.length; i++) {
    oldNo.push(o);
    newNo.push(nn);
    if (ops[i][0] !== "+") o++;
    if (ops[i][0] !== "-") nn++;
  }
  var changed = [];
  for (var j = 0; j < ops.length; j++) if (ops[j][0] !== " ") changed.push(j);
  if (!changed.length) return { text: "", added: 0, removed: 0 };
  var hunks = [];
  var from = Math.max(0, changed[0] - ctx);
  var to = Math.min(ops.length - 1, changed[0] + ctx);
  for (var c = 1; c < changed.length; c++) {
    if (changed[c] - ctx <= to + 1) {
      to = Math.min(ops.length - 1, changed[c] + ctx);
    } else {
      hunks.push([from, to]);
      from = Math.max(0, changed[c] - ctx);
      to = Math.min(ops.length - 1, changed[c] + ctx);
    }
  }
  hunks.push([from, to]);
  var body = [];
  var added = 0;
  var removed = 0;
  hunks.forEach(function (h) {
    var oc = 0;
    var nc = 0;
    var rows = [];
    for (var r = h[0]; r <= h[1]; r++) {
      var op = ops[r];
      if (op[0] !== "+") oc++;
      if (op[0] !== "-") nc++;
      if (op[0] === "+") added++;
      if (op[0] === "-") removed++;
      rows.push(op[0] + op[1]);
    }
    var os = oc ? oldNo[h[0]] : oldNo[h[0]] - 1;
    var ns = nc ? newNo[h[0]] : newNo[h[0]] - 1;
    body.push("@@ -" + os + "," + oc + " +" + ns + "," + nc + " @@");
    body.push.apply(body, rows);
  });
  return { text: head.concat(body).join("\n"), added: added, removed: removed };
}

export function gitStageEntry(stage, branch, path) {
  var b = stage && stage[branch];
  return b && Object.prototype.hasOwnProperty.call(b, path) ? b[path] : null;
}

export function gitStagePut(stage, branch, path, content, before, message) {
  if (!stage[branch]) stage[branch] = {};
  var had = stage[branch][path];
  var files = 0;
  var bytes = 0;
  Object.keys(stage).forEach(function (br) {
    Object.keys(stage[br]).forEach(function (p) {
      files++;
      bytes += str(stage[br][p].content).length;
    });
  });
  if (!had && files >= GIT_STAGE_MAX_FILES) {
    return "Error: this reply already changes " + GIT_STAGE_MAX_FILES + " files — commit, then continue in a new message.";
  }
  if (bytes - str(had && had.content).length + str(content).length > GIT_STAGE_MAX_BYTES) {
    return "Error: the staged changes would pass " + Math.round(GIT_STAGE_MAX_BYTES / 1048576) + " MB — commit what is staged first.";
  }
  stage[branch][path] = {
    content: content,
    before: had ? had.before : before,
    existed: had ? had.existed : before != null,
    message: message || (had && had.message) || ""
  };
  return null;
}

export function gitStageFiles(stage, branch) {
  var b = (stage && stage[branch]) || {};
  return Object.keys(b).sort().map(function (p) {
    return { path: p, content: b[p].content, before: b[p].before, existed: !!b[p].existed, message: b[p].message || "" };
  }).filter(function (f) { return f.content !== f.before; });
}

export function gitStageBranches(stage) {
  return Object.keys(stage || {}).filter(function (br) { return gitStageFiles(stage, br).length > 0; });
}

export function gitCommitMessage(files, explicit) {
  var given = str(explicit).trim();
  if (given) return given.slice(0, 200);
  for (var i = 0; i < files.length; i++) {
    if (files[i].message) return String(files[i].message).slice(0, 200);
  }
  var names = files.map(function (f) { return f.path.split("/").pop(); });
  return ("Update " + names.slice(0, 4).join(", ") + (names.length > 4 ? " and " + (names.length - 4) + " more" : "")).slice(0, 200);
}

export function gitStagedPayload(cfg, branch, files, message, baseSha) {
  var diffs = [];
  var added = 0;
  var removed = 0;
  var size = 0;
  var out = files.map(function (f) {
    var d = gitUnifiedDiff(f.path, f.existed ? f.before : null, f.content);
    added += d.added;
    removed += d.removed;
    if (d.text && size < GIT_DIFF_MAX_CHARS) {
      diffs.push(d.text);
      size += d.text.length;
    }
    return {
      path: f.path,
      content: f.content,
      existed: !!f.existed,
      was: f.existed ? gitTextHash(f.before) : null
    };
  });
  var diff = diffs.join("\n");
  if (diff.length > GIT_DIFF_MAX_CHARS) diff = diff.slice(0, GIT_DIFF_MAX_CHARS) + "\n\\ diff cut short";
  return {
    v: 1,
    repo: cfg.repo,
    provider: cfg.provider,
    host: cfg.host || "",
    branch: branch,
    baseSha: baseSha || null,
    message: gitCommitMessage(files, message),
    files: out,
    diff: diff,
    stats: { files: out.length, added: added, removed: removed }
  };
}

export function gitParseStaged(raw, repo, refRe) {
  if (!raw || typeof raw !== "object") return null;
  if (typeof raw.repo !== "string" || raw.repo !== repo) return null;
  var branch = typeof raw.branch === "string" ? raw.branch : "";
  if (!branch || !(refRe || /^[\w./-]{1,100}$/).test(branch)) return null;
  if (!Array.isArray(raw.files) || !raw.files.length || raw.files.length > GIT_STAGE_MAX_FILES) return null;
  var bytes = 0;
  var seen = {};
  var files = [];
  for (var i = 0; i < raw.files.length; i++) {
    var f = raw.files[i];
    if (!f || typeof f !== "object") return null;
    var p = str(f.path).replace(/^\/+|\/+$/g, "");
    if (!p || p.indexOf("..") !== -1 || p.length > 400 || seen[p]) return null;
    seen[p] = true;
    if (f.content !== null && typeof f.content !== "string") return null;
    bytes += str(f.content).length;
    files.push({
      path: p,
      content: f.content,
      existed: !!f.existed,
      was: typeof f.was === "string" && /^[0-9a-f]{8}:\d+$/.test(f.was) ? f.was : null
    });
  }
  if (bytes > GIT_STAGE_MAX_BYTES) return null;
  var message = str(raw.message).trim().slice(0, 200) || gitCommitMessage(files, "");
  var baseSha = typeof raw.baseSha === "string" && /^[0-9a-f]{40,64}$/i.test(raw.baseSha) ? raw.baseSha : null;
  return { repo: repo, branch: branch, baseSha: baseSha, message: message, files: files };
}

function tarString(bytes, start, len) {
  var end = start;
  var stop = start + len;
  while (end < stop && bytes[end] !== 0) end++;
  return new TextDecoder().decode(bytes.subarray(start, end));
}

function tarSize(bytes, start, len) {
  if (bytes[start] & 0x80) {
    var n = 0;
    for (var i = start + 1; i < start + len; i++) n = n * 256 + bytes[i];
    return n;
  }
  var s = tarString(bytes, start, len).replace(/[\s\0]+/g, "");
  return s ? parseInt(s, 8) || 0 : 0;
}

function tarPax(data) {
  var text = new TextDecoder().decode(data);
  var out = {};
  var at = 0;
  while (at < text.length) {
    var sp = text.indexOf(" ", at);
    if (sp === -1) break;
    var len = parseInt(text.slice(at, sp), 10);
    if (!(len > 0)) break;
    var rec = text.slice(sp + 1, at + len);
    var eq = rec.indexOf("=");
    if (eq > 0) out[rec.slice(0, eq)] = rec.slice(eq + 1).replace(/\n$/, "");
    at += len;
  }
  return out;
}

function tarBlank(bytes, off) {
  for (var i = off; i < off + 512; i++) if (bytes[i] !== 0) return false;
  return true;
}

export var TAR_MAX_ENTRIES = 100000;

export function tarEntries(bytes) {
  var out = [];
  var off = 0;
  var longName = null;
  var paxPath = null;
  var paxLink = null;
  var seen = 0;
  while (off + 512 <= bytes.length) {
    if (tarBlank(bytes, off)) break;
    if (++seen > TAR_MAX_ENTRIES) break;
    var name = tarString(bytes, off, 100);
    var size = tarSize(bytes, off + 124, 12);
    if (!(size >= 0) || !Number.isFinite(size)) break;
    var flag = bytes[off + 156];
    var type = flag === 0 ? "0" : String.fromCharCode(flag);
    var magic = tarString(bytes, off + 257, 6);
    var prefix = magic.indexOf("ustar") === 0 ? tarString(bytes, off + 345, 155) : "";
    var modeText = tarString(bytes, off + 100, 8).replace(/[\s\0]+/g, "");
    var mode = modeText ? parseInt(modeText, 8) || 0 : 0;
    var linkName = tarString(bytes, off + 157, 100);
    var start = off + 512;
    var data = bytes.subarray(start, Math.min(bytes.length, start + size));
    var next = start + Math.ceil(size / 512) * 512;
    if (!(next > off)) break;
    off = next;
    if (type === "L") { longName = tarString(data, 0, data.length); continue; }
    if (type === "x") {
      var pax = tarPax(data);
      paxPath = pax.path || null;
      paxLink = pax.linkpath || null;
      continue;
    }
    if (type === "g") continue;
    var full = longName || paxPath || (prefix ? prefix + "/" + name : name);
    var link = paxLink || linkName;
    longName = null;
    paxPath = null;
    paxLink = null;
    out.push({ path: full, type: type, size: size, data: data, mode: mode, link: link });
  }
  return out;
}

function gitLooksBinary(data) {
  var n = Math.min(data.length, 8000);
  for (var i = 0; i < n; i++) if (data[i] === 0) return true;
  return false;
}

export function gitSnapshotFromTar(bytes, options) {
  var opts = options || {};
  var maxFile = Number(opts.maxFileBytes) > 0 ? Number(opts.maxFileBytes) : GIT_ARCHIVE_MAX_FILE_BYTES;
  var maxTotal = Number(opts.maxTotalBytes) > 0 ? Number(opts.maxTotalBytes) : GIT_ARCHIVE_MAX_TOTAL_BYTES;
  var entries = tarEntries(bytes);
  var top = null;
  var shared = entries.length > 0;
  for (var i = 0; i < entries.length && shared; i++) {
    var first = entries[i].path.split("/")[0];
    if (top == null) top = first;
    else if (first !== top) shared = false;
    if (entries[i].path.indexOf("/") === -1 && entries[i].type !== "5") shared = false;
  }
  var decoder = new TextDecoder("utf-8");
  var snap = { files: {}, sizes: {}, paths: [], big: {}, binary: {}, partial: false };
  var total = 0;
  entries.forEach(function (e) {
    if (e.type !== "0" && e.type !== "7") return;
    var p = shared ? e.path.split("/").slice(1).join("/") : e.path;
    p = p.replace(/^\.\//, "");
    if (!p) return;
    snap.paths.push(p);
    snap.sizes[p] = e.size;
    if (e.size > maxFile) { snap.big[p] = true; return; }
    if (gitLooksBinary(e.data)) { snap.binary[p] = true; return; }
    if (total + e.size > maxTotal) { snap.partial = true; snap.big[p] = true; return; }
    total += e.size;
    snap.files[p] = decoder.decode(e.data);
  });
  snap.paths.sort();
  return snap;
}

export async function gitGunzip(bytes, maxBytes) {
  var cap = Number(maxBytes) > 0 ? Number(maxBytes) : GIT_ARCHIVE_MAX_TOTAL_BYTES * 2;
  var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  var reader = stream.getReader();
  var parts = [];
  var size = 0;
  while (true) {
    var r = await reader.read();
    if (r.done) break;
    size += r.value.length;
    if (size > cap) {
      try { await reader.cancel(); } catch (e) { }
      throw new Error("archive too large once unpacked");
    }
    parts.push(r.value);
  }
  var out = new Uint8Array(size);
  var at = 0;
  parts.forEach(function (p) { out.set(p, at); at += p.length; });
  return out;
}

export function gitSnapshotList(snap, dir, stage) {
  var base = str(dir).replace(/^\/+|\/+$/g, "");
  var prefix = base ? base + "/" : "";
  var dirs = {};
  var files = {};
  var add = function (p, size) {
    if (prefix && p.indexOf(prefix) !== 0) return;
    var rest = p.slice(prefix.length);
    if (!rest) return;
    var slash = rest.indexOf("/");
    if (slash === -1) files[p] = size;
    else dirs[prefix + rest.slice(0, slash)] = true;
  };
  snap.paths.forEach(function (p) { add(p, snap.sizes[p] || 0); });
  Object.keys(stage || {}).forEach(function (p) {
    if (stage[p].content == null) { delete files[p]; return; }
    add(p, stage[p].content.length);
  });
  var rows = [];
  Object.keys(dirs).sort().forEach(function (d) { rows.push("dir\t" + d); });
  Object.keys(files).sort().forEach(function (f) { rows.push("file\t" + f + " (" + files[f] + " bytes)"); });
  if (!rows.length) {
    if (base && (snap.files[base] != null || snap.sizes[base] != null)) return "'" + base + "' is a file — use read_file.";
    return base ? "Error: no directory '" + base + "' in the repository." : "(empty directory)";
  }
  return rows.join("\n");
}

export function gitSearchTexts(texts, query, options) {
  var opts = options || {};
  var maxMatches = Number(opts.maxMatches) > 0 ? Number(opts.maxMatches) : GIT_SEARCH_MAX_MATCHES;
  var maxChars = Number(opts.maxChars) > 0 ? Number(opts.maxChars) : GIT_SEARCH_MAX_CHARS;
  var ctx = opts.context == null ? GIT_SEARCH_CONTEXT : opts.context;
  var skip = typeof opts.skip === "function" ? opts.skip : function () { return false; };
  var needle = str(query).toLowerCase();
  if (!needle) return { text: "", count: 0, truncated: false };
  var paths = Object.keys(texts).sort();
  var blocks = [];
  var count = 0;
  var used = 0;
  var truncated = false;
  for (var i = 0; i < paths.length; i++) {
    var p = paths[i];
    if (skip(p)) continue;
    var body = texts[p];
    if (typeof body !== "string" || body.toLowerCase().indexOf(needle) === -1) continue;
    var lines = body.split("\n");
    var inFile = 0;
    for (var n = 0; n < lines.length; n++) {
      if (lines[n].toLowerCase().indexOf(needle) === -1) continue;
      if (count >= maxMatches || inFile >= GIT_SEARCH_PER_FILE) { truncated = true; break; }
      var from = Math.max(0, n - ctx);
      var to = Math.min(lines.length - 1, n + ctx);
      var rows = [p + ":" + (n + 1)];
      for (var k = from; k <= to; k++) {
        rows.push((k === n ? "> " : "  ") + (k + 1) + "\t" + lines[k].slice(0, 300));
      }
      var block = rows.join("\n");
      if (used + block.length > maxChars) { truncated = true; break; }
      blocks.push(block);
      used += block.length;
      count++;
      inFile++;
    }
    if (count >= maxMatches || used >= maxChars) { truncated = truncated || i < paths.length - 1; break; }
  }
  var text = blocks.join("\n\n");
  if (truncated && text) text += "\n\n[more matches not shown — narrow the query]";
  return { text: text, count: count, truncated: truncated };
}

function gitFragmentRows(fragment, needles, startLine, ctx) {
  var lines = str(fragment).split("\n");
  var hit = -1;
  for (var i = 0; i < lines.length && hit === -1; i++) {
    var low = lines[i].toLowerCase();
    for (var j = 0; j < needles.length; j++) {
      if (needles[j] && low.indexOf(needles[j]) !== -1) { hit = i; break; }
    }
  }
  if (hit === -1) hit = 0;
  var from = Math.max(0, hit - ctx);
  var to = Math.min(lines.length - 1, hit + ctx);
  var rows = [];
  for (var k = from; k <= to; k++) {
    var no = startLine > 0 ? String(startLine + k) + "\t" : "";
    rows.push((k === hit ? "> " : "  ") + no + lines[k].slice(0, 300));
  }
  return { rows: rows, line: startLine > 0 ? startLine + hit : 0 };
}

export function gitFormatMatches(items, query, options) {
  var opts = options || {};
  var ctx = opts.context == null ? GIT_SEARCH_CONTEXT : opts.context;
  var maxChars = Number(opts.maxChars) > 0 ? Number(opts.maxChars) : GIT_SEARCH_MAX_CHARS;
  var cap = Number(opts.maxItems) > 0 ? Number(opts.maxItems) : 10;
  var q = str(query).toLowerCase();
  var out = [];
  var used = 0;
  for (var i = 0; i < (items || []).length && out.length < cap; i++) {
    var it = items[i] || {};
    var path = str(it.path);
    if (!path) continue;
    var block;
    if (Array.isArray(it.text_matches) && it.text_matches.length) {
      var parts = [];
      it.text_matches.slice(0, 2).forEach(function (m) {
        var needles = (m.matches || []).map(function (x) { return str(x && x.text).toLowerCase(); });
        needles.push(q);
        parts.push(gitFragmentRows(m.fragment, needles, 0, ctx).rows.join("\n"));
      });
      block = path + "\n" + parts.join("\n  …\n");
    } else if (it.data != null) {
      var start = Number(it.startline) > 0 ? Number(it.startline) : 0;
      var got = gitFragmentRows(it.data, [q], start, ctx);
      block = path + (got.line ? ":" + got.line : "") + "\n" + got.rows.join("\n");
    } else {
      block = path;
    }
    if (used + block.length > maxChars && out.length) break;
    out.push(block);
    used += block.length;
  }
  return out.length ? out.join("\n\n") : "No matches.";
}

function gitB64(text) {
  var bytes = new TextEncoder().encode(str(text));
  var bin = "";
  for (var i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

function gitSeg(p) { return String(p).split("/").map(encodeURIComponent).join("/"); }

function gitJsonOf(r) { try { return JSON.parse(r.text); } catch (e) { return null; } }

export async function gitCommitFiles(cfg, call, branch, files, message, fallback) {
  if (!files.length) return { ok: true, sha: null, files: [] };
  var repo = cfg.repo;
  var r;
  var j;
  if (cfg.provider === "github") {
    r = await call("/repos/" + repo + "/git/ref/heads/" + gitSeg(branch));
    j = gitJsonOf(r);
    var head = r.ok && j && j.object ? j.object.sha : null;
    if (!head) return { ok: false, error: "HTTP " + r.status + " resolving branch '" + branch + "'" };
    r = await call("/repos/" + repo + "/git/commits/" + head);
    j = gitJsonOf(r);
    var baseTree = r.ok && j && j.tree ? j.tree.sha : null;
    if (!baseTree) return { ok: false, error: "HTTP " + r.status + " reading commit " + head.slice(0, 7) };
    var modes = {};
    r = await call("/repos/" + repo + "/git/trees/" + baseTree + "?recursive=1");
    j = gitJsonOf(r);
    ((j && j.tree) || []).forEach(function (e) { if (e && e.type === "blob") modes[e.path] = e.mode; });
    var tree = files.map(function (f) {
      var mode = modes[f.path] || "100644";
      if (f.content == null) return { path: f.path, mode: mode, type: "blob", sha: null };
      return { path: f.path, mode: mode, type: "blob", content: f.content };
    }).filter(function (e) { return e.sha !== null || modes[e.path]; });
    if (!tree.length) return { ok: true, sha: head, files: [] };
    r = await call("/repos/" + repo + "/git/trees", { method: "POST", body: { base_tree: baseTree, tree: tree } });
    j = gitJsonOf(r);
    if (!r.ok || !j || !j.sha) return { ok: false, error: "HTTP " + r.status + " writing the tree: " + str(r.text).slice(0, 200) };
    r = await call("/repos/" + repo + "/git/commits", { method: "POST", body: { message: message, tree: j.sha, parents: [head] } });
    j = gitJsonOf(r);
    if (!r.ok || !j || !j.sha) return { ok: false, error: "HTTP " + r.status + " writing the commit: " + str(r.text).slice(0, 200) };
    var made = j.sha;
    r = await call("/repos/" + repo + "/git/refs/heads/" + gitSeg(branch), { method: "PATCH", body: { sha: made, force: false } });
    if (!r.ok) return { ok: false, error: "HTTP " + r.status + " moving '" + branch + "' (it may have moved meanwhile): " + str(r.text).slice(0, 200) };
    return { ok: true, sha: made, files: files.map(function (f) { return f.path; }) };
  }
  if (cfg.provider === "gitlab") {
    var actions = files.map(function (f) {
      if (f.content == null) return { action: "delete", file_path: f.path };
      return { action: f.existed ? "update" : "create", file_path: f.path, content: f.content, encoding: "text" };
    });
    r = await call("/projects/" + encodeURIComponent(repo) + "/repository/commits", {
      method: "POST", body: { branch: branch, commit_message: message, actions: actions }
    });
    j = gitJsonOf(r);
    if (r.ok && j && j.id) return { ok: true, sha: j.id, files: files.map(function (f) { return f.path; }) };
    if (!fallback) return { ok: false, error: "HTTP " + r.status + " committing: " + str(r.text).slice(0, 200) };
    return gitCommitEach(cfg, branch, files, message, fallback);
  }
  if (cfg.provider === "gitea") {
    var ops = [];
    for (var i = 0; i < files.length; i++) {
      var f = files[i];
      var sha = null;
      var got = await call("/repos/" + repo + "/contents/" + gitSeg(f.path) + "?ref=" + encodeURIComponent(branch));
      var gj = got.ok ? gitJsonOf(got) : null;
      if (gj && gj.sha) sha = gj.sha;
      if (f.content == null) {
        if (sha) ops.push({ operation: "delete", path: f.path, sha: sha });
        continue;
      }
      var op = { operation: sha ? "update" : "create", path: f.path, content: gitB64(f.content) };
      if (sha) op.sha = sha;
      ops.push(op);
    }
    if (!ops.length) return { ok: true, sha: null, files: [] };
    r = await call("/repos/" + repo + "/contents", { method: "POST", body: { branch: branch, message: message, files: ops } });
    j = gitJsonOf(r);
    if (r.ok) {
      return { ok: true, sha: (j && j.commit && j.commit.sha) || null, files: ops.map(function (o) { return o.path; }) };
    }
    if (fallback && (r.status === 404 || r.status === 405 || r.status === 501)) {
      return gitCommitEach(cfg, branch, files, message, fallback);
    }
    return { ok: false, error: "HTTP " + r.status + " committing: " + str(r.text).slice(0, 200) };
  }
  if (fallback) return gitCommitEach(cfg, branch, files, message, fallback);
  return { ok: false, error: "this provider cannot commit" };
}

async function gitCommitEach(cfg, branch, files, message, provider) {
  var done = [];
  var failed = [];
  for (var i = 0; i < files.length; i++) {
    var f = files[i];
    try {
      if (f.content == null) {
        if (await provider.deleteFile(cfg, branch, f.path, message)) done.push(f.path);
        else failed.push(f.path);
      } else {
        var w = await provider.writeFile(cfg, branch, f.path, f.content, message);
        if (/^Error:/.test(str(w))) failed.push(f.path); else done.push(f.path);
      }
    } catch (e) {
      failed.push(f.path);
    }
  }
  if (failed.length) {
    return { ok: done.length > 0, partial: true, sha: null, files: done, failed: failed,
      error: "could not commit " + failed.join(", ") };
  }
  return { ok: true, sha: null, files: done, perFile: true };
}

export function gitArchiveUrl(cfg, apiBase, branch) {
  if (cfg.provider === "github") return apiBase + "/repos/" + cfg.repo + "/tarball/" + gitSeg(branch);
  if (cfg.provider === "gitlab") {
    return apiBase + "/projects/" + encodeURIComponent(cfg.repo) + "/repository/archive.tar.gz?sha=" + encodeURIComponent(branch);
  }
  if (cfg.provider === "gitea") return apiBase + "/repos/" + cfg.repo + "/archive/" + gitSeg(branch) + ".tar.gz";
  return null;
}

export var GIT_ARCHIVE_MAX_REDIRECTS = 4;
var GIT_ARCHIVE_HOST_HOPS = { "api.github.com": { "codeload.github.com": 1 } };

function gitHostOf(url) {
  try { return new URL(url).hostname.toLowerCase(); } catch (e) { return ""; }
}

export function gitArchiveKeepsAuth(fromUrl, toUrl) {
  var from = gitHostOf(fromUrl);
  var to = gitHostOf(toUrl);
  if (!from || !to) return false;
  if (from === to) return true;
  return !!(GIT_ARCHIVE_HOST_HOPS[from] && GIT_ARCHIVE_HOST_HOPS[from][to]);
}

function gitHeadersWithoutAuth(headers) {
  var out = {};
  for (var k in headers) {
    if (!Object.prototype.hasOwnProperty.call(headers, k)) continue;
    var lk = k.toLowerCase();
    if (lk === "authorization" || lk === "private-token" || lk === "cookie") continue;
    out[k] = headers[k];
  }
  return out;
}

export async function gitFetchArchive(url, headers, capBytes, fetchImpl) {
  var run = fetchImpl || fetch;
  var origin = url;
  var at = url;
  var sendHeaders = headers || {};
  var res = null;
  for (var hop = 0; hop <= GIT_ARCHIVE_MAX_REDIRECTS; hop++) {
    res = await run(at, { headers: sendHeaders, redirect: "manual" });
    if (!(res.status >= 300 && res.status < 400)) break;
    var loc = res.headers && res.headers.get ? res.headers.get("location") : null;
    try { if (res.body && res.body.cancel) await res.body.cancel(); } catch (e) { }
    if (!loc || hop === GIT_ARCHIVE_MAX_REDIRECTS) return { ok: false, status: res.status };
    var next;
    try { next = new URL(loc, at).toString(); } catch (e) { return { ok: false, status: res.status }; }
    if (!/^https:/i.test(next)) return { ok: false, status: res.status };
    if (!gitArchiveKeepsAuth(origin, next)) sendHeaders = gitHeadersWithoutAuth(sendHeaders);
    at = next;
  }
  if (!res.ok || !res.body) return { ok: false, status: res.status };
  var len = Number(res.headers && res.headers.get && res.headers.get("content-length"));
  if (Number.isFinite(len) && len > capBytes) {
    try { await res.body.cancel(); } catch (e) { }
    return { ok: false, tooBig: true };
  }
  var reader = res.body.getReader();
  var parts = [];
  var size = 0;
  while (true) {
    var r = await reader.read();
    if (r.done) break;
    size += r.value.length;
    if (size > capBytes) {
      try { await reader.cancel(); } catch (e) { }
      return { ok: false, tooBig: true };
    }
    parts.push(r.value);
  }
  var bytes = new Uint8Array(size);
  var at = 0;
  parts.forEach(function (p) { bytes.set(p, at); at += p.length; });
  return { ok: true, bytes: bytes };
}

function gitCiLine(name, state, url) {
  return "- " + name + ": " + state + (url ? " (" + url + ")" : "");
}

export async function gitCiStatus(cfg, call, ref) {
  var repo = cfg.repo;
  var r;
  var j;
  var lines = [];
  if (cfg.provider === "github") {
    r = await call("/repos/" + repo + "/commits/" + gitSeg(ref) + "/check-runs?per_page=30");
    j = r.ok ? gitJsonOf(r) : null;
    var runs = (j && j.check_runs) || [];
    runs.forEach(function (c) {
      lines.push(gitCiLine(c.name, c.status === "completed" ? (c.conclusion || "completed") : c.status, c.html_url));
    });
    r = await call("/repos/" + repo + "/commits/" + gitSeg(ref) + "/status");
    var st = r.ok ? gitJsonOf(r) : null;
    ((st && st.statuses) || []).forEach(function (s) {
      lines.push(gitCiLine(s.context, s.state + (s.description ? " — " + s.description : ""), s.target_url));
    });
    if (!lines.length) {
      if (!r.ok && !runs.length) return "Error: HTTP " + r.status + " reading CI status for '" + ref + "'.";
      return "No CI checks or statuses are reported for '" + ref + "' yet. CI may not be set up, or it has not started — try again shortly.";
    }
    var pending = runs.some(function (c) { return c.status !== "completed"; }) || (st && st.state === "pending" && (st.statuses || []).length);
    var failing = runs.some(function (c) { return c.conclusion && !/^(success|neutral|skipped)$/.test(c.conclusion); }) ||
      ((st && st.statuses) || []).some(function (s) { return s.state === "failure" || s.state === "error"; });
    return "CI for '" + ref + "': " + (failing ? "FAILING" : pending ? "still running" : "passing") + "\n" + lines.slice(0, 40).join("\n");
  }
  if (cfg.provider === "gitlab") {
    var bySha = /^[0-9a-f]{7,64}$/i.test(ref);
    r = await call("/projects/" + encodeURIComponent(repo) + "/pipelines?per_page=3&" + (bySha ? "sha=" : "ref=") + encodeURIComponent(ref));
    if (!r.ok) return "Error: HTTP " + r.status + " reading pipelines for '" + ref + "'.";
    var pipes = gitJsonOf(r) || [];
    if (!pipes.length) return "No pipelines for '" + ref + "' yet. CI may not be set up, or it has not started.";
    var top = pipes[0];
    lines.push("Pipeline #" + top.id + ": " + top.status + (top.web_url ? " (" + top.web_url + ")" : ""));
    r = await call("/projects/" + encodeURIComponent(repo) + "/pipelines/" + top.id + "/jobs?per_page=30");
    (r.ok ? gitJsonOf(r) || [] : []).forEach(function (job) {
      lines.push(gitCiLine((job.stage ? job.stage + "/" : "") + job.name, job.status, job.web_url));
    });
    return "CI for '" + ref + "':\n" + lines.slice(0, 40).join("\n");
  }
  if (cfg.provider === "gitea") {
    r = await call("/repos/" + repo + "/commits/" + gitSeg(ref) + "/status");
    if (!r.ok) return "Error: HTTP " + r.status + " reading CI status for '" + ref + "'.";
    j = gitJsonOf(r) || {};
    (j.statuses || []).forEach(function (s) {
      lines.push(gitCiLine(s.context, (s.status || s.state || "") + (s.description ? " — " + s.description : ""), s.target_url));
    });
    if (!lines.length) return "No CI statuses are reported for '" + ref + "' yet.";
    return "CI for '" + ref + "': " + (j.state || "unknown") + "\n" + lines.slice(0, 40).join("\n");
  }
  return "This provider does not report CI status.";
}
