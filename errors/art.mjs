// Status codes are figlet 'Slant Relief' (npx figlet -f 'Slant Relief' 429); String.raw keeps backslashes literal.
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
    // A name: never translated.
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

// Squared off because centered `<pre>` lines split ragged rows, and editors strip trailing spaces.
export function squareOff(art) {
  const lines = art.split("\n");
  const width = Math.max(...lines.map((line) => line.length));
  // Empty lines stay empty so the newline `<pre>` drops does not become a row of spaces.
  return lines
    .map((line) => (line === "" ? line : line + " ".repeat(width - line.length)))
    .join("\n");
}

// A monospace cell is 0.6em, so the cap is 0.92 * 100vw / (columns * 0.6), less 5% for rounding.
export function codeFontSize(art) {
  const columns = Math.max(...art.split("\n").map((line) => line.length));
  const vw = Math.floor((0.92 * 100 / (columns * 0.6)) * 0.95 * 10) / 10;
  return `min(${vw}vw, 15px)`;
}

// Matches the 404 window's inner width.
const INNER = 45;

const esc = (text) =>
  text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const span = (cls, text) => `<span class="${cls}">${text}</span>`;
const frame = (text) => span("nf-frame", text);

// Padding is computed on the visible text before markup is added.
const pad = (visible, what) => {
  if (visible.length > INNER) {
    throw new Error(
      `error window line is ${visible.length} columns, ${INNER} is the limit: ${what}`
    );
  }
  return " ".repeat(INNER - visible.length);
};

/** `lines`: null for a blank line, { sys } for a notice, { nym, text } for speech. */
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
