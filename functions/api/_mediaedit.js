export var MEDIA_EDIT_MAX_IMAGES = 4;

export var MEDIA_EDIT_NEEDS_PRO = "Editing a picture needs Nymbot Pro — select a Pro model with ?model first, then send ?image <how to change it> with the picture. Standard ?image only draws from a description.";

var EDIT_INTENT_EXCLUDE = new RegExp(
  "\\b(?:python|javascript|typescript|java|kotlin|swift|rust|golang|dart|c\\+\\+|" +
  "html|css|svg|canvas|matplotlib|pillow|imagemagick|ffmpeg|photoshop|gimp|code|script|function|" +
  "library|api|endpoint|component|ascii)\\b", "i");

var ATTACHED_BLOCK_RE = /\n*---\s*attached image:[^\n]*---[ \t]*(?:\n\s*https?:\/\/[^\s<>"']+)?/gi;
var IMAGE_URL_RE = /https?:\/\/[^\s<>"']+\.(?:png|jpe?g|gif|webp)(?:\?[^\s<>"']*)?/gi;

export function mediaEditPrompt(prompt) {
  return String(prompt || "")
    .replace(ATTACHED_BLOCK_RE, " ")
    .replace(IMAGE_URL_RE, " ")
    .replace(/[ \t]+/g, " ")
    .replace(/\s*\n\s*/g, "\n")
    .trim();
}

export function mediaEditBody(family, prompt, refs) {
  var p = String(prompt || "").slice(0, 2000);
  var images = (refs || []).filter(function (u) { return /^https?:\/\//.test(String(u)); })
    .slice(0, MEDIA_EDIT_MAX_IMAGES);
  if (family === "google") {
    return { prompt: p, image_input: images, aspect_ratio: "match_input_image", image_size: "1K" };
  }
  if (family === "bfl") {
    return { prompt: p, input_images: images };
  }
  return { prompt: p, image: images };
}

export function mediaEditCapable(model) {
  return !!(model && model.edit);
}

function editKeys(table) {
  return Object.keys(table || {}).filter(function (k) { return mediaEditCapable(table[k]); });
}

function creditsOf(model) {
  return Number(model && model.credits) || 0;
}

export function mediaEditChoose(model, table, refs, defaultKey) {
  var has = !!(refs && refs.length);
  if (!model) return { error: "No image model is available right now." };
  if (!has) {
    if (model.needsImage) {
      return { error: model.label + " edits a picture you send rather than drawing from nothing — attach one in the same message, or pick another generator (?image models)." };
    }
    return { model: model, editing: false };
  }
  if (mediaEditCapable(model)) return { model: model, editing: true };
  var ceiling = creditsOf(model);
  var keys = editKeys(table);
  if (!keys.length) {
    return { error: "None of the image models can edit a picture right now — send the description without the picture to draw a new one." };
  }
  var pick = null;
  if (defaultKey && table[defaultKey] && mediaEditCapable(table[defaultKey])
    && creditsOf(table[defaultKey]) <= ceiling) {
    pick = table[defaultKey];
  }
  if (!pick) {
    keys.forEach(function (k) {
      var m = table[k];
      if (creditsOf(m) > ceiling) return;
      if (!pick || creditsOf(m) < creditsOf(pick)) pick = m;
    });
  }
  if (!pick) {
    var cheapest = null;
    var cheapestKey = "";
    keys.forEach(function (k) {
      if (!cheapest || creditsOf(table[k]) < creditsOf(cheapest)) { cheapest = table[k]; cheapestKey = k; }
    });
    return { error: model.label + " cannot edit a picture, and every model that can costs more than it does. "
      + cheapest.label + " can, for " + creditsOf(cheapest) + " Pro credits — send ?image --model "
      + cheapestKey + " <how to change it> with the picture to use it." };
  }
  return {
    model: pick,
    editing: true,
    swappedFrom: model,
    note: model.label + " cannot edit a picture, so " + pick.label + " made this edit."
  };
}

export function mediaEditIntent(message, pictureCount) {
  if (!pictureCount) return null;
  var text = mediaEditPrompt(message);
  if (!text || text.length > 400) return null;
  if (/^\s*[?!@]/.test(text)) return null;
  if (EDIT_INTENT_EXCLUDE.test(text)) return null;
  if (/^\s*(?:what|which|who|why|how|when|where|is|are|do|does|did|can you (?:read|see|describe|explain|tell))\b/i.test(text)) return null;
  var m = /^(?:please\s+)?(?:can you\s+|could you\s+|would you\s+)?(?:edit|change|modify|retouch|alter)\s+(?:this|the|my|that)\s+(?:picture|image|photo|photograph|pic)\s*(?::|,|-|to|so(?: that)?|and)\s*([\s\S]+)$/i.exec(text);
  if (!m) return null;
  if (!(m[1] || "").trim()) return null;
  return { kind: "image", prompt: text.trim(), modelKey: "", inferred: true, edit: true };
}

export function mediaEditListLine(model) {
  if (!model) return "";
  if (model.needsImage) return " — edits a picture you send (needs one)";
  if (model.edit) return " — can also edit a picture you send";
  return "";
}
