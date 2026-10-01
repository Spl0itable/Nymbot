import { parseMarkdown, inlineText } from "./_filemd.js";
import { zipFiles } from "./_filezip.js";

export var XLSX_MAX_ROWS = 20000;
export var XLSX_MAX_COLS = 200;
export var XLSX_MAX_SHEETS = 20;

var XML_HEAD = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n";
var W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
var R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
var REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships";
var DOC_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

export function xmlEscape(s) {
  return String(s)
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\ufffe\uffff]/g, "")
    .replace(/[\ud800-\udbff](?![\udc00-\udfff])|(^|[^\ud800-\udbff])[\udc00-\udfff]/g, "$1")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function isoNow() {
  return new Date().toISOString().replace(/\.\d+Z$/, "Z");
}

function coreXml(title) {
  return XML_HEAD + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">" +
    (title ? "<dc:title>" + xmlEscape(title) + "</dc:title>" : "") +
    "<dc:creator>Nymbot</dc:creator><dcterms:created xsi:type=\"dcterms:W3CDTF\">" + isoNow() + "</dcterms:created>" +
    "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">" + isoNow() + "</dcterms:modified></cp:coreProperties>";
}

function docxRun(span, extra) {
  var props = "";
  if (span.code) props += "<w:rStyle w:val=\"CodeChar\"/>";
  else if (span.href) props += "<w:rStyle w:val=\"Hyperlink\"/>";
  if (span.b || (extra && extra.b)) props += "<w:b/>";
  if (span.i) props += "<w:i/>";
  if (span.s) props += "<w:strike/>";
  var parts = String(span.text).split("\n");
  var body = parts.map(function (p, k) {
    return (k ? "<w:br/>" : "") + (p ? "<w:t xml:space=\"preserve\">" + xmlEscape(p) + "</w:t>" : "");
  }).join("");
  return "<w:r>" + (props ? "<w:rPr>" + props + "</w:rPr>" : "") + body + "</w:r>";
}

function docxInlines(inlines, links, extra) {
  return (inlines || []).map(function (span) {
    if (span.href) {
      var id = links.add(span.href);
      return "<w:hyperlink r:id=\"" + id + "\" w:history=\"1\">" + docxRun(span, extra) + "</w:hyperlink>";
    }
    return docxRun(span, extra);
  }).join("");
}

function para(style, inner, more) {
  var ppr = (style ? "<w:pStyle w:val=\"" + style + "\"/>" : "") + (more || "");
  return "<w:p>" + (ppr ? "<w:pPr>" + ppr + "</w:pPr>" : "") + inner + "</w:p>";
}

function docxBlocks(blocks, ctx) {
  var out = [];
  blocks.forEach(function (block) {
    if (block.type === "heading") {
      out.push(para("Heading" + block.level, docxInlines(block.inlines, ctx.links)));
    } else if (block.type === "para") {
      out.push(para(ctx.quote ? "Quote" : ctx.listLevel != null ? "ListParagraph" : "", docxInlines(block.inlines, ctx.links), ctx.listNum ? ctx.listNum() : ""));
    } else if (block.type === "code") {
      var lines = String(block.text).split("\n");
      lines.forEach(function (l) {
        out.push(para("Code", "<w:r><w:t xml:space=\"preserve\">" + xmlEscape(l) + "</w:t></w:r>"));
      });
    } else if (block.type === "quote") {
      out.push.apply(out, docxBlocks(block.blocks, Object.assign({}, ctx, { quote: true })));
    } else if (block.type === "hr") {
      out.push(para("", "", "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BBBBBB\"/></w:pBdr>"));
    } else if (block.type === "pagebreak") {
      out.push("<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>");
    } else if (block.type === "list") {
      var level = ctx.listLevel == null ? 0 : Math.min(8, ctx.listLevel + 1);
      var numId = ctx.numbering.add(block.ordered, block.start);
      block.items.forEach(function (item) {
        var first = true;
        var inner = item.blocks.length ? item.blocks : [{ type: "para", inlines: [] }];
        var mark = item.task === null ? null : (item.task ? "\u2611 " : "\u2610 ");
        var withTask = inner.map(function (b, k) {
          if (k === 0 && mark && b.type === "para") return Object.assign({}, b, { inlines: [{ text: mark, b: false, i: false, code: false, s: false, href: "" }].concat(b.inlines) });
          return b;
        });
        out.push.apply(out, docxBlocks(withTask, Object.assign({}, ctx, {
          listLevel: level,
          listNum: function () {
            if (!first) return "<w:ind w:left=\"" + (720 * (level + 1)) + "\"/>";
            first = false;
            return "<w:numPr><w:ilvl w:val=\"" + level + "\"/><w:numId w:val=\"" + numId + "\"/></w:numPr>";
          }
        })));
      });
    } else if (block.type === "table") {
      var cols = block.head.length;
      var grid = "<w:tblGrid>" + new Array(cols).fill("<w:gridCol/>").join("") + "</w:tblGrid>";
      var row = function (cells, head) {
        return "<w:tr>" + (head ? "<w:trPr><w:tblHeader/></w:trPr>" : "") + cells.map(function (cell, c) {
          var jc = block.align[c] === "right" ? "right" : block.align[c] === "center" ? "center" : "";
          return "<w:tc><w:tcPr>" + (head ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"EEF0F4\"/>" : "") + "</w:tcPr>" +
            "<w:p><w:pPr><w:spacing w:before=\"40\" w:after=\"40\"/>" + (jc ? "<w:jc w:val=\"" + jc + "\"/>" : "") + "</w:pPr>" +
            docxInlines(cell, ctx.links, head ? { b: true } : null) + "</w:p></w:tc>";
        }).join("") + "</w:tr>";
      };
      out.push("<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/></w:tblPr>" +
        grid + row(block.head, true) + block.rows.map(function (r) { return row(r, false); }).join("") + "</w:tbl>");
      out.push("<w:p/>");
    }
  });
  return out;
}

function stylesXml() {
  var heading = function (n, size) {
    return "<w:style w:type=\"paragraph\" w:styleId=\"Heading" + n + "\"><w:name w:val=\"heading " + n + "\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/>" +
      "<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"" + (n <= 2 ? 360 : 240) + "\" w:after=\"120\"/><w:outlineLvl w:val=\"" + (n - 1) + "\"/></w:pPr>" +
      "<w:rPr><w:b/><w:sz w:val=\"" + size + "\"/><w:szCs w:val=\"" + size + "\"/></w:rPr></w:style>";
  };
  return XML_HEAD + "<w:styles xmlns:w=\"" + W_NS + "\">" +
    "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"Calibri\" w:cs=\"Calibri\"/><w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault>" +
    "<w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"276\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>" +
    "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>" +
    heading(1, 36) + heading(2, 30) + heading(3, 26) + heading(4, 24) + heading(5, 22) + heading(6, 22) +
    "<w:style w:type=\"paragraph\" w:styleId=\"Code\"><w:name w:val=\"Code\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F4\"/><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/><w:sz w:val=\"19\"/><w:szCs w:val=\"19\"/></w:rPr></w:style>" +
    "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"C8C8CC\"/></w:pBdr><w:ind w:left=\"567\"/></w:pPr><w:rPr><w:color w:val=\"60606A\"/></w:rPr></w:style>" +
    "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"60\"/><w:contextualSpacing/></w:pPr></w:style>" +
    "<w:style w:type=\"character\" w:styleId=\"CodeChar\"><w:name w:val=\"Code Char\"/><w:rPr><w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/><w:sz w:val=\"20\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F4\"/></w:rPr></w:style>" +
    "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:rPr><w:color w:val=\"1752B8\"/><w:u w:val=\"single\"/></w:rPr></w:style>" +
    "<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:tblPr><w:tblBorders>" +
    ["top", "left", "bottom", "right", "insideH", "insideV"].map(function (side) { return "<w:" + side + " w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"C8C8CC\"/>"; }).join("") +
    "</w:tblBorders><w:tblCellMar><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>" +
    "</w:styles>";
}

function numberingXml(lists) {
  var levels = function (ordered) {
    var out = "";
    for (var l = 0; l < 9; l++) {
      var bullet = ["\u2022", "\u25e6", "\u25aa"][l % 3];
      out += "<w:lvl w:ilvl=\"" + l + "\"><w:start w:val=\"1\"/><w:numFmt w:val=\"" + (ordered ? (l % 3 === 1 ? "lowerLetter" : l % 3 === 2 ? "lowerRoman" : "decimal") : "bullet") + "\"/>" +
        "<w:lvlText w:val=\"" + (ordered ? "%" + (l + 1) + "." : bullet) + "\"/><w:lvlJc w:val=\"left\"/>" +
        "<w:pPr><w:ind w:left=\"" + (720 * (l + 1)) + "\" w:hanging=\"360\"/></w:pPr>" +
        (ordered ? "" : "<w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\"/></w:rPr>") + "</w:lvl>";
    }
    return out;
  };
  var body = "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>" + levels(false) + "</w:abstractNum>" +
    "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>" + levels(true) + "</w:abstractNum>";
  lists.forEach(function (l, i) {
    body += "<w:num w:numId=\"" + (i + 1) + "\"><w:abstractNumId w:val=\"" + (l.ordered ? 1 : 0) + "\"/>" +
      (l.ordered ? "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"" + Math.max(0, l.start | 0) + "\"/></w:lvlOverride>" : "") + "</w:num>";
  });
  return XML_HEAD + "<w:numbering xmlns:w=\"" + W_NS + "\">" + body + "</w:numbering>";
}

export async function renderDocx(markdown, opts) {
  var o = opts || {};
  var blocks = Array.isArray(markdown) ? markdown : parseMarkdown(markdown);
  var linkList = [];
  var lists = [];
  var ctx = {
    links: {
      add: function (href) {
        var at = linkList.indexOf(href);
        if (at === -1) { linkList.push(href); at = linkList.length - 1; }
        return "rIdL" + (at + 1);
      }
    },
    numbering: {
      add: function (ordered, start) { lists.push({ ordered: ordered, start: start }); return lists.length; }
    }
  };
  var body = docxBlocks(blocks, ctx).join("");
  var a4 = o.paper === "a4";
  var sect = "<w:sectPr><w:pgSz w:w=\"" + (a4 ? 11906 : 12240) + "\" w:h=\"" + (a4 ? 16838 : 15840) + "\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>";
  var documentXml = XML_HEAD + "<w:document xmlns:w=\"" + W_NS + "\" xmlns:r=\"" + R_NS + "\"><w:body>" + (body || "<w:p/>") + sect + "</w:body></w:document>";
  var docRels = XML_HEAD + "<Relationships xmlns=\"" + REL_NS + "\">" +
    "<Relationship Id=\"rIdS\" Type=\"" + DOC_REL + "/styles\" Target=\"styles.xml\"/>" +
    "<Relationship Id=\"rIdN\" Type=\"" + DOC_REL + "/numbering\" Target=\"numbering.xml\"/>" +
    linkList.map(function (href, i) {
      return "<Relationship Id=\"rIdL" + (i + 1) + "\" Type=\"" + DOC_REL + "/hyperlink\" Target=\"" + xmlEscape(href) + "\" TargetMode=\"External\"/>";
    }).join("") + "</Relationships>";
  var types = XML_HEAD + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
    "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
    "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>" +
    "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>" +
    "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>" +
    "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>";
  var rels = XML_HEAD + "<Relationships xmlns=\"" + REL_NS + "\">" +
    "<Relationship Id=\"rId1\" Type=\"" + DOC_REL + "/officeDocument\" Target=\"word/document.xml\"/>" +
    "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>";
  return await zipFiles([
    { name: "[Content_Types].xml", data: types },
    { name: "_rels/.rels", data: rels },
    { name: "word/document.xml", data: documentXml },
    { name: "word/_rels/document.xml.rels", data: docRels },
    { name: "word/styles.xml", data: stylesXml() },
    { name: "word/numbering.xml", data: numberingXml(lists) },
    { name: "docProps/core.xml", data: coreXml(o.title) }
  ]);
}

var XLSX_FUNCS = /^(SUM|AVERAGE|MIN|MAX|COUNT|COUNTA|COUNTBLANK|ROUND|ROUNDUP|ROUNDDOWN|INT|ABS|MOD|POWER|SQRT|PRODUCT|MEDIAN|IF|IFERROR|AND|OR|NOT|SUMIF|SUMIFS|COUNTIF|COUNTIFS|AVERAGEIF|AVERAGEIFS|CONCAT|CONCATENATE|LEN|UPPER|LOWER|TRIM|LEFT|RIGHT|MID|TODAY|DATE|YEAR|MONTH|DAY|TEXT|VALUE|STDEV|VAR|LARGE|SMALL|RANK|PI|EXP|LN|LOG|LOG10|CEILING|FLOOR|SIGN|TRUE|FALSE)$/i;

export function safeFormula(text) {
  var f = String(text || "");
  if (f.charAt(0) !== "=" || f.length < 2 || f.length > 500) return null;
  var body = f.slice(1);
  if (/[!\[\]{}@'`\\]|https?:|\|/i.test(body)) return null;
  var stripped = body.replace(/"[^"]*"/g, "\"\"");
  if (/"/.test(stripped.replace(/""/g, ""))) return null;
  var names = stripped.match(/[A-Za-z_][A-Za-z0-9_.]*(?=\s*\()/g) || [];
  for (var i = 0; i < names.length; i++) if (!XLSX_FUNCS.test(names[i])) return null;
  var bare = stripped.replace(/[A-Za-z_][A-Za-z0-9_.]*\s*\(/g, "(").replace(/\$?[A-Za-z]{1,3}\$?\d{1,7}/g, "0").replace(/TRUE|FALSE/gi, "0");
  if (/[A-Za-z_]/.test(bare)) return null;
  if (!/^[0-9.\s+\-*/^%(),:<>=&"]*$/.test(bare)) return null;
  return body;
}

var NUMBER = /^-?(?:\d{1,15}|\d{1,3}(?:,\d{3}){1,4})(?:\.\d+)?(?:[eE][+-]?\d{1,3})?$/;

export function cellValue(raw) {
  var s = String(raw == null ? "" : raw);
  var t = s.trim();
  if (!t) return { kind: "empty" };
  if (NUMBER.test(t) && !/^-?0\d/.test(t)) {
    var n = Number(t.replace(/,/g, ""));
    if (Number.isFinite(n)) return { kind: "number", value: n };
  }
  if (/^(true|false)$/i.test(t)) return { kind: "bool", value: /^true$/i.test(t) };
  if (t.charAt(0) === "=") {
    var f = safeFormula(t);
    if (f) return { kind: "formula", value: f };
  }
  return { kind: "string", value: s };
}

function colName(i) {
  var s = "";
  i++;
  while (i > 0) {
    var m = (i - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    i = Math.floor((i - 1) / 26);
  }
  return s;
}

export function sheetName(raw, used) {
  var base = String(raw || "Sheet").replace(/[\[\]:*?\/\\\u0000-\u001f]/g, " ").replace(/^'+|'+$/g, "").replace(/\s+/g, " ").trim().slice(0, 31) || "Sheet";
  var name = base;
  var n = 2;
  while (used.has(name.toLowerCase())) {
    var tail = " (" + n++ + ")";
    name = base.slice(0, 31 - tail.length) + tail;
  }
  used.add(name.toLowerCase());
  return name;
}

function sheetXml(rows, opts) {
  var widths = [];
  var out = [];
  rows.forEach(function (row, r) {
    var cells = [];
    row.forEach(function (raw, c) {
      var ref = colName(c) + (r + 1);
      var v = cellValue(raw);
      var len = String(raw == null ? "" : raw).length;
      widths[c] = Math.max(widths[c] || 0, Math.min(60, len));
      var style = r === 0 && opts.header ? " s=\"1\"" : "";
      if (v.kind === "empty") return;
      if (v.kind === "number") cells.push("<c r=\"" + ref + "\"" + style + "><v>" + v.value + "</v></c>");
      else if (v.kind === "bool") cells.push("<c r=\"" + ref + "\"" + style + " t=\"b\"><v>" + (v.value ? 1 : 0) + "</v></c>");
      else if (v.kind === "formula") cells.push("<c r=\"" + ref + "\"" + style + "><f>" + xmlEscape(v.value) + "</f></c>");
      else cells.push("<c r=\"" + ref + "\"" + style + " t=\"inlineStr\"><is><t xml:space=\"preserve\">" + xmlEscape(v.value) + "</t></is></c>");
    });
    out.push("<row r=\"" + (r + 1) + "\">" + cells.join("") + "</row>");
  });
  var cols = widths.length ? "<cols>" + widths.map(function (w, i) {
    return "<col min=\"" + (i + 1) + "\" max=\"" + (i + 1) + "\" width=\"" + Math.max(9, Math.round((w || 0) * 1.1 + 2)) + "\" customWidth=\"1\"/>";
  }).join("") + "</cols>" : "";
  var pane = opts.header && rows.length > 1
    ? "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
    : "<sheetViews><sheetView workbookViewId=\"0\"/></sheetViews>";
  return XML_HEAD + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"" + R_NS + "\">" +
    pane + "<sheetFormatPr defaultRowHeight=\"15\"/>" + cols + "<sheetData>" + out.join("") + "</sheetData></worksheet>";
}

export async function renderXlsx(sheets, opts) {
  var o = opts || {};
  var used = new Set();
  var list = sheets.slice(0, XLSX_MAX_SHEETS).map(function (s, i) {
    return { name: sheetName(s.name || ("Sheet" + (i + 1)), used), rows: s.rows, header: s.header !== false };
  });
  if (!list.length) list.push({ name: sheetName("Sheet1", used), rows: [], header: false });
  var files = [];
  var types = XML_HEAD + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
    "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
    "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" +
    "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>" +
    list.map(function (s, i) { return "<Override PartName=\"/xl/worksheets/sheet" + (i + 1) + ".xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"; }).join("") +
    "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>";
  files.push({ name: "[Content_Types].xml", data: types });
  files.push({ name: "_rels/.rels", data: XML_HEAD + "<Relationships xmlns=\"" + REL_NS + "\">" +
    "<Relationship Id=\"rId1\" Type=\"" + DOC_REL + "/officeDocument\" Target=\"xl/workbook.xml\"/>" +
    "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>" });
  files.push({ name: "xl/workbook.xml", data: XML_HEAD + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"" + R_NS + "\"><sheets>" +
    list.map(function (s, i) { return "<sheet name=\"" + xmlEscape(s.name) + "\" sheetId=\"" + (i + 1) + "\" r:id=\"rIdW" + (i + 1) + "\"/>"; }).join("") +
    "</sheets><calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>" });
  files.push({ name: "xl/_rels/workbook.xml.rels", data: XML_HEAD + "<Relationships xmlns=\"" + REL_NS + "\">" +
    list.map(function (s, i) { return "<Relationship Id=\"rIdW" + (i + 1) + "\" Type=\"" + DOC_REL + "/worksheet\" Target=\"worksheets/sheet" + (i + 1) + ".xml\"/>"; }).join("") +
    "<Relationship Id=\"rIdStyles\" Type=\"" + DOC_REL + "/styles\" Target=\"styles.xml\"/></Relationships>" });
  files.push({ name: "xl/styles.xml", data: XML_HEAD + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" +
    "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>" +
    "<fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill><fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFEEF0F4\"/><bgColor indexed=\"64\"/></patternFill></fill></fills>" +
    "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>" +
    "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>" +
    "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\"/></cellXfs>" +
    "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>" });
  list.forEach(function (s, i) {
    files.push({ name: "xl/worksheets/sheet" + (i + 1) + ".xml", data: sheetXml(s.rows, { header: s.header }) });
  });
  files.push({ name: "docProps/core.xml", data: coreXml(o.title) });
  return await zipFiles(files);
}

export function tablesFromMarkdown(markdown) {
  var blocks = parseMarkdown(markdown);
  var out = [];
  var heading = "";
  var walk = function (list) {
    list.forEach(function (b) {
      if (b.type === "heading") heading = inlineText(b.inlines);
      if (b.type === "table") {
        out.push({ name: heading || "", rows: [b.head.map(inlineText)].concat(b.rows.map(function (r) { return r.map(inlineText); })) });
      }
      if (b.type === "quote") walk(b.blocks);
    });
  };
  walk(blocks);
  return out;
}
