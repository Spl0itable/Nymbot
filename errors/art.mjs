// The drawings on an error page, and the one rule for how wide they may be.
//
// Both are the 404's, generalized: `404.html` draws its own by hand, which is
// fine for one page and would not survive eight of them drifting apart. The
// window in particular is padded to the character — the generator counts the
// columns so that a line of dialogue can be edited without recounting the
// frame, and fails the build rather than shipping a crooked box.

// Every hero a page can carry, with what it says out loud. The status codes are
// figlet output in "Slant Relief", the font the 404 draws its own 404 in;
// regenerate one, or add one, with:
//
//     npx figlet -f 'Slant Relief' 429
//
// figlet is not a dependency: the art is baked in here so that `npm run build`
// stays offline, exactly like the translation cache. `logo` is the wordmark
// from the top of index.html, copied rather than redrawn so the two cannot
// drift apart. `String.raw` throughout, because both fonts are very nearly all
// backslashes and every one of them is literal.
export const HERO_ART = {
  "5XX": {
    label: "Error 5XX",
    art: String.raw`
___/\\\\\\\\\\\\\\\___/\\\_______/\\\__/\\\_______/\\\_        
 __\/\\\///////////___\///\\\___/\\\/__\///\\\___/\\\/__       
  __\/\\\________________\///\\\\\\/______\///\\\\\\/____      
   __\/\\\\\\\\\\\\_________\//\\\\__________\//\\\\______     
    __\////////////\\\________\/\\\\___________\/\\\\______    
     _____________\//\\\_______/\\\\\\__________/\\\\\\_____   
      __/\\\________\/\\\_____/\\\////\\\______/\\\////\\\___  
       _\//\\\\\\\\\\\\\/____/\\\/___\///\\\__/\\\/___\///\\\_ 
        __\/////////////_____\///_______\///__\///_______\///__`,
  },

  "1XXX": {
    label: "Error 1XXX",
    art: String.raw`
______/\\\__/\\\_______/\\\__/\\\_______/\\\__/\\\_______/\\\_        
 __/\\\\\\\_\///\\\___/\\\/__\///\\\___/\\\/__\///\\\___/\\\/__       
  _\/////\\\___\///\\\\\\/______\///\\\\\\/______\///\\\\\\/____      
   _____\/\\\_____\//\\\\__________\//\\\\__________\//\\\\______     
    _____\/\\\______\/\\\\___________\/\\\\___________\/\\\\______    
     _____\/\\\______/\\\\\\__________/\\\\\\__________/\\\\\\_____   
      _____\/\\\____/\\\////\\\______/\\\////\\\______/\\\////\\\___  
       _____\/\\\__/\\\/___\///\\\__/\\\/___\///\\\__/\\\/___\///\\\_ 
        _____\///__\///_______\///__\///_______\///__\///_______\///__`,
  },

  "403": {
    label: "Error 403",
    art: String.raw`
____________/\\\________/\\\\\\\________/\\\\\\\\\\__        
 __________/\\\\\______/\\\/////\\\____/\\\///////\\\_       
  ________/\\\/\\\_____/\\\____\//\\\__\///______/\\\__      
   ______/\\\/\/\\\____\/\\\_____\/\\\_________/\\\//___     
    ____/\\\/__\/\\\____\/\\\_____\/\\\________\////\\\__    
     __/\\\\\\\\\\\\\\\\_\/\\\_____\/\\\___________\//\\\_   
      _\///////////\\\//__\//\\\____/\\\___/\\\______/\\\__  
       ___________\/\\\_____\///\\\\\\\/___\///\\\\\\\\\/___ 
        ___________\///________\///////_______\/////////_____`,
  },

  "429": {
    label: "Error 429",
    art: String.raw`
____________/\\\_______/\\\\\\\\\__________/\\\\\\\\\____        
 __________/\\\\\_____/\\\///////\\\______/\\\///////\\\__       
  ________/\\\/\\\____\///______\//\\\____/\\\______\//\\\_      
   ______/\\\/\/\\\______________/\\\/____\//\\\_____/\\\\\_     
    ____/\\\/__\/\\\___________/\\\//_______\///\\\\\\\\/\\\_    
     __/\\\\\\\\\\\\\\\\_____/\\\//____________\////////\/\\\_   
      _\///////////\\\//____/\\\/_____________/\\________/\\\__  
       ___________\/\\\_____/\\\\\\\\\\\\\\\__\//\\\\\\\\\\\/___ 
        ___________\///_____\///////////////____\///////////_____`,
  },

  "logo": {
    label: "Nymbot",
    // A name, not prose: never translated, and never sent to be.
    fixed: true,
    art: String.raw`
                                  ##\                  ##\
                                  ## |                 ## |
#######\  ##\   ##\ ######\####\  #######\   ######\ ######\
##  __##\ ## |  ## |##  _##  _##\ ##  __##\ ##  __##\\_##  _|
## |  ## |## |  ## |## / ## / ## |## |  ## |## /  ## | ## |
## |  ## |## |  ## |## | ## | ## |## |  ## |## |  ## | ## |##\
## |  ## |\####### |## | ## | ## |#######  |\######  | \####  |
\__|  \__| \____## |\__| \__| \__|\_______/  \______/   \____/
          ##\   ## |
          \######  |
           \______/`,
  },
};

// `text-align: center` centers each line of a `<pre>` on its own width, so a
// drawing with ragged rows comes apart down the middle of the page. figlet pads
// its output and the window generator below pads its own; the wordmark lifted
// out of index.html sits inside a flex box there and does not, so every hero is
// squared off here rather than trusting the source to carry trailing spaces
// that an editor is free to strip.
export function squareOff(art) {
  const lines = art.split("\n");
  const width = Math.max(...lines.map((line) => line.length));
  // An empty line is left empty: it has nothing to centre, and padding the one
  // every entry opens with would turn the newline that `<pre>` drops into a row
  // of spaces that it keeps.
  return lines
    .map((line) => (line === "" ? line : line + " ".repeat(width - line.length)))
    .join("\n");
}

// The art is sized in `vw` capped by a pixel maximum so it scales down with the
// viewport instead of wrapping — see the `.nf-art` comment in styles.css for
// where this comes from. A monospace cell is 0.6em wide, so the widest a glyph
// row may be rendered is 0.92 * 100vw / (columns * 0.6), and 5% is held back
// from that so a rounding error is never a clipped column.
export function codeFontSize(art) {
  const columns = Math.max(...art.split("\n").map((line) => line.length));
  const vw = Math.floor((0.92 * 100 / (columns * 0.6)) * 0.95 * 10) / 10;
  return `min(${vw}vw, 15px)`;
}

// Characters between the two frame pipes. The 404's window is this wide, and
// every window here matches it so the pages look like one set.
const INNER = 45;

const esc = (text) =>
  text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const span = (cls, text) => `<span class="${cls}">${text}</span>`;
const frame = (text) => span("nf-frame", text);

// Every row is built from its visible text first and wrapped in markup after,
// because the markup is invisible and would make the padding a guess.
const pad = (visible, what) => {
  if (visible.length > INNER) {
    throw new Error(
      `error window line is ${visible.length} columns, ${INNER} is the limit: ${what}`
    );
  }
  return " ".repeat(INNER - visible.length);
};

/**
 * The ASCII chat window. `lines` is the transcript, top to bottom:
 *
 *   null                      a blank line
 *   { sys: "* … *" }          a system notice
 *   { nym: "you", text: "…" } someone saying something
 */
export function windowArt({ channel, status, lines }) {
  const rows = [];

  rows.push(` ${frame("," + "-".repeat(INNER) + ".")}`);

  const head = `  ${channel}`;
  const tail = `${status} `;
  rows.push(
    ` ${frame("|")}  ${span("nf-chan", esc(channel))}` +
      pad(head + tail, `${channel} / ${status}`) +
      `${esc(status)} ${frame("|")}`
  );

  rows.push(` ${frame("|" + "-".repeat(INNER) + "|")}`);

  for (const line of lines) {
    if (line === null) {
      rows.push(` ${frame("|")}${" ".repeat(INNER)}${frame("|")}`);
      continue;
    }
    if (line.sys) {
      const visible = `  ${line.sys}`;
      rows.push(
        ` ${frame("|")}  ${span("nf-sys", esc(line.sys))}` +
          pad(visible, line.sys) +
          frame("|")
      );
      continue;
    }
    const nym = `<${line.nym}>`;
    const visible = `  ${nym}  ${line.text}`;
    rows.push(
      ` ${frame("|")}  ${span("nf-nym", esc(nym))}  ${esc(line.text)}` +
        pad(visible, `${nym} ${line.text}`) +
        frame("|")
    );
  }

  rows.push(` ${frame("'" + "-".repeat(INNER) + "'")}`);

  return "\n" + rows.join("\n");
}
