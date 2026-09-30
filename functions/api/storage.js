// D1-backed user storage: flair shop, encrypted settings, profile mirror, PM wrap archive, channel archive.

import { ledgerCall } from "./_ledger.js";
import { apiDebtCollect } from "./_apibill.js";
import { bgDriver } from "./_background.js";
export { NymLedger } from "./_ledger.js";
import {
  botPqSelfFromEnv,
  fetchPqAnnouncementKey,
  pqAnnouncementEventsFromD1,
  userPqRecordFromEvents,
  buildPqGiftWrappedDM
} from "./_pq.js";
import {
  hasD1,
  replica,
  shopGet,
  shopPut,
  shopGetActiveMany,
  invoiceGet,
  invoiceHas,
  invoicePut,
  codeGet
} from "./_d1.js";
import {
  getPublicKey,
  getEventHash,
  signEvent,
  serializeEvent,
  nip44ConversationKey,
  nip44Encrypt,
  nip44Decrypt,
  botBase64Encode,
  botBase64Decode,
  hkdfExpand,
  nip44PaddedLen,
  randomTimestampNow,
  buildGiftWrappedDM,
  buildGiftWrappedDMPair,
  verifyClientAuth,
  enforceAuthReplay,
  authReplayRequired,
  parseNwcUri,
  invoicePaymentConfirmed,
  sanitizeInput,
  bytesToHex,
  hexToBytes,
  utf8ToBytes,
  concatBytes,
  randomBytes,
  hmac,
  sha256,
  secp256k1,
  schnorr,
  BOT_LIGHTNING_ADDRESS,
  botLightningAddresses,
  CLIENT_CORS_HEADERS,
} from "./_shared.js";
import { isNymchatClient } from "./_client.js";
import { mcpHostBlocked } from "./_mcp.js";

function shopKnown(id) {
  return typeof id === "string" && Object.prototype.hasOwnProperty.call(SHOP_CATALOG, id);
}

var SHOP_CATALOG = {
  "style-satoshi": { price: 21420, type: "message-style", tier: "legendary" },
  "style-glitch": { price: 10101, type: "message-style" },
  "style-aurora": { price: 2424, type: "message-style" },
  "style-neon": { price: 1984, type: "message-style" },
  "style-ghost": { price: 666, type: "message-style" },
  "style-matrix": { price: 1337, type: "message-style", tier: "legendary" },
  "style-fire": { price: 911, type: "message-style" },
  "style-ice": { price: 777, type: "message-style" },
  "style-rainbow": { price: 2222, type: "message-style" },
  "style-ocean": { price: 1500, type: "message-style" },
  "style-sakura": { price: 3000, type: "message-style" },
  "style-galaxy": { price: 4444, type: "message-style" },
  "style-toxic": { price: 1300, type: "message-style" },
  "style-gold": { price: 8888, type: "message-style" },
  "style-vapor": { price: 1995, type: "message-style" },
  "style-blood": { price: 1313, type: "message-style" },
  "style-royal": { price: 6000, type: "message-style" },
  "style-circuit": { price: 2048, type: "message-style" },
  "flair-crown": { price: 5000, type: "nickname-flair" },
  "flair-diamond": { price: 10000, type: "nickname-flair", tier: "legendary" },
  "flair-skull": { price: 1666, type: "nickname-flair" },
  "flair-star": { price: 2500, type: "nickname-flair" },
  "flair-lightning": { price: 2100, type: "nickname-flair" },
  "flair-heart": { price: 1111, type: "nickname-flair" },
  "flair-mask": { price: 4200, type: "nickname-flair", tier: "legendary" },
  "flair-rocket": { price: 2300, type: "nickname-flair" },
  "flair-shield": { price: 1900, type: "nickname-flair" },
  "flair-flame": { price: 1200, type: "nickname-flair" },
  "flair-snowflake": { price: 1400, type: "nickname-flair" },
  "flair-moon": { price: 1600, type: "nickname-flair" },
  "flair-sun": { price: 1500, type: "nickname-flair" },
  "flair-leaf": { price: 900, type: "nickname-flair" },
  "flair-music": { price: 1100, type: "nickname-flair" },
  "flair-eye": { price: 1800, type: "nickname-flair" },
  "flair-anchor": { price: 1000, type: "nickname-flair" },
  "flair-gem": { price: 3300, type: "nickname-flair" },
  "supporter-badge": { price: 42069, type: "supporter" },
  "cosmetic-aura-gold": { price: 3500, type: "cosmetic" },
  "cosmetic-redacted": { price: 2800, type: "cosmetic" },
  "cosmetic-aura-neon": { price: 3200, type: "cosmetic" },
  "cosmetic-aura-rainbow": { price: 11000, type: "cosmetic", tier: "legendary" },
  "cosmetic-frost": { price: 2600, type: "cosmetic" },
  "cosmetic-aura-cosmic": { price: 5000, type: "cosmetic" },
  "cosmetic-aura-phoenix": { price: 12000, type: "cosmetic", tier: "legendary" },
  "cosmetic-bubble-hologram": { price: 13500, type: "cosmetic", tier: "legendary" },
  "flair-genesis": { price: 25000, type: "nickname-flair", tier: "legendary", maxSupply: 100 },
  "style-eclipse": { price: 9000, type: "message-style", maxSupply: 1000, startsAt: 1735689600000, endsAt: 1798761600000 },
  "style-crt": { price: 12000, type: "message-style", tier: "legendary", maxSupply: 250, startsAt: 1735689600000, endsAt: 1798761600000 },
  "bundle-starter": { price: 3000, type: "bundle", bundle: ["flair-flame", "style-ice", "cosmetic-frost"] },
  "bundle-legendary": { price: 30000, type: "bundle", bundle: ["cosmetic-aura-phoenix", "cosmetic-aura-rainbow", "cosmetic-bubble-hologram"] },
  "bundle-everything": { price: 149999, type: "bundle", bundle: [] }
};

// Derived from the catalog so the Everything Pack can never drift out of sync.
SHOP_CATALOG["bundle-everything"].bundle = Object.keys(SHOP_CATALOG).filter(function (id) {
  var c = SHOP_CATALOG[id];
  return c.type !== "bundle" && !c.maxSupply;
});

// Returns null when purchasable, or an { error, status } describing why not.
function shopItemAvailability(cat, now) {
  if (!cat) return { error: "Unknown shop item.", status: 400 };
  if (typeof cat.startsAt === "number" && now < cat.startsAt) {
    return { error: "This item isn't available yet.", status: 409 };
  }
  if (typeof cat.endsAt === "number" && now > cat.endsAt) {
    return { error: "This limited drop has ended.", status: 409 };
  }
  return null;
}

function shopClaimVisibleTo(claim, userPubkey) {
  if (!claim || typeof claim !== "object") return false;
  var payer = String(claim.paidBy || "").toLowerCase();
  var owner = String(claim.pubkey || "").toLowerCase();
  return payer === userPubkey || owner === userPubkey;
}

function shopClaimReplay(claim, userPubkey) {
  var owner = String(claim.pubkey || "").toLowerCase();
  var own = owner === userPubkey;
  return { itemId: claim.itemId, code: own ? claim.code : null, gift: claim.gift, recipient: claim.pubkey, alreadyClaimed: true };
}

function shopGenerateCode() {
  return "NYM-" + bytesToHex(randomBytes(16)).toUpperCase();
}

// BOLT11 invoice from the bot's Lightning address (LUD-21).
async function botGenerateInvoice(env, sats, zapRequest, comment) {
  var addresses = botLightningAddresses(env);
  if (!addresses.length) return { error: "Bot Lightning address misconfigured.", status: 500 };
  var lastError = null;
  for (var ai = 0; ai < addresses.length; ai++) {
    var attempt = await botInvoiceFromAddress(env, addresses[ai], sats, zapRequest, comment);
    if (!attempt.error) return attempt;
    lastError = attempt;
  }
  return lastError;
}

async function botInvoiceFromAddress(env, address, sats, zapRequest, comment) {
  var lnAddr = String(address).split("@");
  if (lnAddr.length !== 2) return { error: "Bot Lightning address misconfigured.", status: 500 };
  var lnurlData;
  try {
    var lnRes = await fetch("https://" + lnAddr[1] + "/.well-known/lnurlp/" + lnAddr[0], { headers: { "Accept": "application/json" } });
    lnurlData = await lnRes.json();
  } catch (e) {
    return { error: "Could not reach the bot's Lightning wallet.", status: 502 };
  }
  if (!lnurlData || !lnurlData.callback) return { error: "Bot Lightning wallet returned an invalid response.", status: 502 };
  var milli = sats * 1000;
  if (milli < (lnurlData.minSendable || 0) || milli > (lnurlData.maxSendable || Infinity)) {
    return { error: "Item price is outside the bot wallet's accepted range.", status: 400 };
  }
  var cbUrl;
  try {
    cbUrl = new URL(lnurlData.callback);
    cbUrl.searchParams.set("amount", String(milli));
    if (zapRequest && lnurlData.allowsNostr && lnurlData.nostrPubkey) {
      cbUrl.searchParams.set("nostr", JSON.stringify(zapRequest));
    }
    if (comment && lnurlData.commentAllowed) {
      cbUrl.searchParams.set("comment", String(comment).slice(0, lnurlData.commentAllowed));
    }
  } catch (e) {
    return { error: "Bot Lightning wallet callback is invalid.", status: 502 };
  }
  var invData;
  try {
    var invRes = await fetch(cbUrl.toString(), { headers: { "Accept": "application/json" } });
    invData = await invRes.json();
  } catch (e) {
    return { error: "Could not generate a Lightning invoice.", status: 502 };
  }
  if (!invData || !invData.pr) return { error: (invData && invData.reason) || "Bot wallet did not return an invoice.", status: 502 };
  var hasVerify = invData.verify && /^https:\/\//i.test(invData.verify);
  var canNip57 = zapRequest && lnurlData.allowsNostr &&
    typeof lnurlData.nostrPubkey === "string" && /^[0-9a-f]{64}$/i.test(lnurlData.nostrPubkey);
  var hasNwc = !!(env.BOT_NWC_URI && parseNwcUri(env.BOT_NWC_URI));
  if (!hasVerify && !canNip57 && !hasNwc) {
    return { error: "Bot Lightning wallet supports neither LUD-21 verification nor NIP-57 zap receipts.", status: 502 };
  }
  return {
    pr: invData.pr,
    verifyMethod: hasVerify ? "lud21" : (canNip57 ? "nip57" : "nwc"),
    verifyUrl: hasVerify ? invData.verify : null,
    providerPubkey: canNip57 ? lnurlData.nostrPubkey.toLowerCase() : null,
    serverVerify: hasNwc
  };
}

// Over the /api WebSocket the socket's pinned pubkey stands in for per-request signatures.
function clientAuthOk(context, body, userPubkey) {
  if (context && context._wsAuthedPubkey) return context._wsAuthedPubkey === userPubkey;
  if (context && context._storageAuthed && context._storageAuthed.body === body && context._storageAuthed.pubkey === userPubkey) return true;
  return verifyClientAuth(body.auth, userPubkey, { url: context.request.url, action: body.action, body: body });
}

async function storageReplayRefusal(context, body) {
  if (!body || !context || context._wsAuthedPubkey || !authReplayRequired(body.action, context.env || {})) return null;
  var pk = typeof body.pubkey === "string" ? body.pubkey.toLowerCase() : "";
  if (!/^[0-9a-f]{64}$/.test(pk) || !clientAuthOk(context, body, pk)) return null;
  context._storageAuthed = { body: body, pubkey: pk };
  var rp = await enforceAuthReplay(ledgerCall, context.env, body.auth && body.auth.id);
  if (rp.ok) return null;
  return new Response(JSON.stringify({ error: rp.error }), {
    status: rp.status, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
  });
}

var STORAGE_PQ_RELAYS = [
  "wss://relay.damus.io",
  "wss://nos.lol",
  "wss://relay.primal.net",
  "wss://offchain.pub"
];

// Hybrid post-quantum when the recipient announced an ML-KEM key; never throws, falls back to NIP-17.
async function buildStoragePqDM(env, botPrivkey, botPubkey, recipient, msg) {
  try {
    var botPq = botPqSelfFromEnv(env);
    var recipKem = null;
    if (botPq) {
      // D1 archive first, where the recipient's own client resolves keys; signature-verified either way.
      try {
        var db = hasD1(env.DB_CHANNELS) ? replica(env.DB_CHANNELS) : null;
        var d1Events = await pqAnnouncementEventsFromD1(db, recipient);
        if (d1Events) recipKem = userPqRecordFromEvents(d1Events, recipient);
      } catch (e) { recipKem = null; }
      if (!recipKem) {
        recipKem = await fetchPqAnnouncementKey(recipient, STORAGE_PQ_RELAYS, 2500);
      }
    }
    return buildPqGiftWrappedDM(msg, botPrivkey, botPubkey, recipient, recipKem);
  } catch (e) {
    try {
      return buildPqGiftWrappedDM(msg, botPrivkey, botPubkey, recipient, null);
    } catch (e2) {
      return null;
    }
  }
}

async function handleShopAction(context, body, botPrivkey, botPubkey) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_SHOP)) return json({ error: "Shop is not configured (missing DB_SHOP binding)." }, 503);

  // Public and unauthenticated: read-only, non-sensitive flair lookup.
  if (body.action === "shop-status") {
    var rawPks = Array.isArray(body.pubkeys) ? body.pubkeys.slice(0, 100) : [];
    var pks = [];
    for (var i = 0; i < rawPks.length; i++) {
      var pk = rawPks[i];
      if (typeof pk === "string" && /^[0-9a-f]{64}$/i.test(pk)) pks.push(pk.toLowerCase());
    }
    var forceFresh = new Set();
    if (Array.isArray(body.fresh)) {
      body.fresh.forEach(function (pk) {
        if (typeof pk === "string" && /^[0-9a-f]{64}$/i.test(pk)) forceFresh.add(pk.toLowerCase());
      });
    }
    var statuses = {};
    var cacheLookups = await Promise.all(pks.map(async function (pk) {
      if (forceFresh.has(pk)) return [pk, null];
      return [pk, await readCacheGet("/shop-status/" + pk)];
    }));
    var misses = [];
    cacheLookups.forEach(function (pair) {
      if (pair[1] && pair[1].st) statuses[pair[0]] = pair[1].st;
      else misses.push(pair[0]);
    });
    if (misses.length) {
      var actives = await shopGetActiveMany(replica(env.DB_SHOP), misses);
      misses.forEach(function (pk) {
        var st = { active: actives[pk].active, updatedAt: actives[pk].updatedAt };
        statuses[pk] = st;
        readCachePut(context, "/shop-status/" + pk, { st: st }, SHOP_READ_TTL);
      });
    }
    return json({ statuses: statuses });
  }

  // Public and unauthenticated: remaining supply for limited items.
  if (body.action === "shop-supply") {
    var wantIds = Array.isArray(body.itemIds) ? body.itemIds.slice(0, 50) : [];
    var limitedIds = [];
    wantIds.forEach(function (id) {
      var c = SHOP_CATALOG[String(id)];
      if (c && c.maxSupply) limitedIds.push(String(id));
    });
    var supply = {};
    if (limitedIds.length) {
      var sup = await ledgerCall(env, { op: "shop-supply", itemIds: limitedIds });
      var counts = (sup && sup.counts) || {};
      limitedIds.forEach(function (id) {
        var max = SHOP_CATALOG[id].maxSupply;
        var c = counts[id] || { minted: 0, reserved: 0 };
        var used = (c.minted || 0) + (c.reserved || 0);
        supply[id] = {
          max: max,
          minted: c.minted || 0,
          remaining: Math.max(0, max - used)
        };
      });
    }
    return json({ supply: supply });
  }

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!clientAuthOk(context, body, userPubkey)) {
    return json({ error: "Authentication failed" }, 401);
  }

  if (body.action === "shop-get") {
    var rec = await shopGet(env.DB_SHOP, userPubkey);
    return json({ owned: rec.owned, active: rec.active, updatedAt: rec.updatedAt });
  }

  if (body.action === "shop-set-active") {
    var rec = await shopGet(env.DB_SHOP, userPubkey);
    var want = (body.active && typeof body.active === "object") ? body.active : {};
    var nextStyle = null;
    if (typeof want.style === "string" && rec.owned[want.style] &&
      SHOP_CATALOG[want.style] && SHOP_CATALOG[want.style].type === "message-style") {
      nextStyle = want.style;
    }
    var nextFlair = Array.isArray(want.flair) ? want.flair.filter(function (id) {
      return rec.owned[id] && SHOP_CATALOG[id] && SHOP_CATALOG[id].type === "nickname-flair";
    }) : [];
    var nextCos = Array.isArray(want.cosmetics) ? want.cosmetics.filter(function (id) {
      return rec.owned[id] && SHOP_CATALOG[id] && SHOP_CATALOG[id].type === "cosmetic";
    }) : [];
    // Authoritative edition numbers so other clients can render e.g. Genesis #42.
    var nextEditions = {};
    [nextStyle].concat(nextFlair).forEach(function (id) {
      if (id && rec.owned[id] && rec.owned[id].edition) nextEditions[id] = rec.owned[id].edition;
    });
    rec.active = {
      style: nextStyle,
      flair: nextFlair,
      cosmetics: nextCos,
      supporter: !!want.supporter && !!rec.owned["supporter-badge"],
      editions: nextEditions
    };
    await shopPut(env.DB_SHOP, userPubkey, rec);
    readCachePut(context, "/shop-status/" + userPubkey, { st: { active: rec.active, updatedAt: rec.updatedAt } }, SHOP_READ_TTL);
    return json({ active: rec.active, updatedAt: rec.updatedAt });
  }

  if (body.action === "shop-buy-invoice") {
    var itemId = String(body.itemId || "");
    if (!shopKnown(itemId)) return json({ error: "Unknown shop item." }, 400);
    var cat = SHOP_CATALOG[itemId];
    var availErr = shopItemAvailability(cat, Date.now());
    if (availErr) return json({ error: availErr.error }, availErr.status);
    var giftTo = null;
    if (body.recipientPubkey && /^[0-9a-f]{64}$/i.test(body.recipientPubkey)) {
      giftTo = body.recipientPubkey.toLowerCase();
    }
    var inv = await botGenerateInvoice(env, cat.price, body.zapRequest, body.comment);
    if (inv.error) return json({ error: inv.error }, inv.status || 502);
    var invoiceId = bytesToHex(sha256(utf8ToBytes(inv.pr)));
    // The reservation expires (freeing the slot) if the invoice is never paid.
    if (cat.maxSupply) {
      var resv = await ledgerCall(env, { op: "shop-reserve", itemId: itemId, max: cat.maxSupply, invoiceId: invoiceId, user: userPubkey, ttl: 1800 });
      if (resv && resv._noLedger) return json({ error: "Service temporarily unavailable." }, 503);
      if (resv && resv.soldOut) return json({ error: "This limited edition is sold out." }, 409);
      if (!resv || resv.error) return json({ error: (resv && resv.error) || "Could not reserve this item." }, 400);
    }
    await invoicePut(env.DB_INVOICES, "shop", "pending", invoiceId, {
      pubkey: userPubkey,
      recipientPubkey: giftTo,
      itemId: itemId,
      amountSats: cat.price,
      pr: inv.pr,
      verifyMethod: inv.verifyMethod,
      verifyUrl: inv.verifyUrl,
      providerPubkey: inv.providerPubkey,
      createdAt: Date.now()
    });
    return json({
      pr: inv.pr,
      verify: inv.verifyMethod === "lud21" ? inv.verifyUrl : null,
      serverVerify: !!inv.serverVerify,
      needsReceipt: inv.verifyMethod === "nip57" && !inv.serverVerify,
      invoiceId: invoiceId
    });
  }

  if (body.action === "shop-check") {
    var scId = String(body.invoiceId || "");
    if (!/^[0-9a-f]{64}$/i.test(scId)) return json({ error: "Invalid invoice reference." }, 400);
    if (await invoiceHas(env.DB_INVOICES, "shop", "claimed", scId)) return json({ paid: true, claimed: true });
    var scRec = await invoiceGet(env.DB_INVOICES, "shop", "pending", scId);
    if (!scRec) return json({ error: "Unknown or expired invoice." }, 404);
    if (scRec.pubkey !== userPubkey) return json({ error: "This invoice belongs to a different user." }, 403);
    return json({ paid: await invoicePaymentConfirmed(env, scRec, body.receipt) });
  }

  if (body.action === "shop-claim") {
    var invoiceId = String(body.invoiceId || "");
    if (!/^[0-9a-f]{64}$/i.test(invoiceId)) return json({ error: "Invalid invoice reference." }, 400);
    var prevClaim = await invoiceGet(env.DB_INVOICES, "shop", "claimed", invoiceId);
    if (prevClaim) {
      if (!shopClaimVisibleTo(prevClaim, userPubkey)) return json({ error: "This invoice belongs to a different user." }, 403);
      return json(shopClaimReplay(prevClaim, userPubkey));
    }
    var pending = await invoiceGet(env.DB_INVOICES, "shop", "pending", invoiceId);
    if (!pending) return json({ error: "Unknown or expired invoice." }, 404);
    if (pending.pubkey !== userPubkey) return json({ error: "This invoice belongs to a different user." }, 403);
    if (!await invoicePaymentConfirmed(env, pending, body.receipt)) {
      return json({ error: "Payment not confirmed yet." }, 402);
    }
    if (!shopKnown(pending.itemId)) return json({ error: "Unknown shop item." }, 400);
    var claimCat = SHOP_CATALOG[pending.itemId];
    var recipient = userPubkey;
    var isGift = false;
    if (pending.recipientPubkey && /^[0-9a-f]{64}$/i.test(pending.recipientPubkey) &&
      pending.recipientPubkey !== userPubkey) {
      recipient = pending.recipientPubkey.toLowerCase();
      isGift = true;
    }
    // Bundles grant each component item, each with its own recovery code.
    var bundleItems = null;
    if (Array.isArray(claimCat.bundle) && claimCat.bundle.length) {
      bundleItems = claimCat.bundle
        .filter(function (bid) { return SHOP_CATALOG[bid]; })
        .map(function (bid) { return { itemId: bid, code: shopGenerateCode() }; });
    }
    var code = shopGenerateCode();
    // Atomic claim-and-grant via the ledger DO (single-use invoice gate).
    var claimRes = await ledgerCall(env, {
      op: "shop-claim", invoiceId: invoiceId, recipient: recipient, itemId: pending.itemId,
      code: code, amountSats: pending.amountSats, gift: isGift,
      bundle: bundleItems,
      edition: claimCat.maxSupply ? { max: claimCat.maxSupply } : null,
      claimData: { paidBy: userPubkey, gift: isGift }
    });
    if (claimRes && claimRes._noLedger) return json({ error: "Service temporarily unavailable." }, 503);
    if (claimRes && claimRes.alreadyClaimed) {
      var prev = claimRes.prev;
      if (prev && shopClaimVisibleTo(prev, userPubkey)) return json(shopClaimReplay(prev, userPubkey));
      return json({ error: "This payment was already claimed." }, 409);
    }
    if (claimRes && claimRes.soldOut) {
      return json({
        soldOut: true, refunded: claimRes.refunded, balance: claimRes.balance,
        error: "This limited edition sold out before your payment arrived, so it came back to you as " +
          claimRes.refunded + " standard Nymbot credit" + (claimRes.refunded === 1 ? "" : "s") + "."
      }, 409);
    }
    if (!claimRes || claimRes.error) return json({ error: (claimRes && claimRes.error) || "Claim failed." }, 400);
    var crec = { owned: claimRes.owned, active: claimRes.active };
    var giftEvent = null;
    if (isGift) {
      var gifterName = typeof body.gifterNym === "string" ? sanitizeInput(body.gifterNym).slice(0, 64) : "";
      var giftMsg = (gifterName ? gifterName + " gifted you " : "You've been gifted ") +
        "a Nymchat shop item. Open the Flair Shop to find it in your inventory.";
      giftEvent = await buildStoragePqDM(env, botPrivkey, botPubkey, recipient, giftMsg);
    }
    return json({
      itemId: pending.itemId, code: isGift ? null : code, gift: isGift, recipient: recipient, giftEvent: giftEvent,
      edition: claimRes.edition || null,
      bundle: bundleItems ? (isGift ? bundleItems.map(function (b) { return { itemId: b.itemId }; }) : bundleItems) : null,
      owned: isGift ? undefined : crec.owned, active: isGift ? undefined : crec.active
    });
  }

  if (body.action === "shop-transfer") {
    var itemId = String(body.itemId || "");
    var toPubkey = String(body.toPubkey || "").toLowerCase();
    if (!shopKnown(itemId)) return json({ error: "Unknown shop item." }, 400);
    if (!/^[0-9a-f]{64}$/.test(toPubkey)) return json({ error: "Invalid recipient pubkey." }, 400);
    if (toPubkey === userPubkey) return json({ error: "Cannot transfer to yourself." }, 400);
    var xfer = await ledgerCall(env, { op: "shop-transfer", from: userPubkey, to: toPubkey, itemId: itemId });
    if (xfer && xfer._noLedger) return json({ error: "Service temporarily unavailable." }, 503);
    if (!xfer || xfer.error) return json({ error: (xfer && xfer.error) || "Transfer failed." }, 403);
    var fromRec = { owned: xfer.owned, active: xfer.active };
    readCacheDelete(context, "/shop-status/" + userPubkey);
    var transferEvent = null;
    try {
      var tName = typeof body.gifterNym === "string" ? sanitizeInput(body.gifterNym).slice(0, 64) : "";
      var tMsg = (tName ? tName + " transferred you " : "You've been transferred ") +
        "a Nymchat shop item. Open the Flair Shop to find it in your inventory.";
      transferEvent = await buildStoragePqDM(env, botPrivkey, botPubkey, toPubkey, tMsg);
    } catch (e) {
      transferEvent = null;
    }
    return json({ ok: true, itemId: itemId, owned: fromRec.owned, active: fromRec.active, giftEvent: transferEvent });
  }

  if (body.action === "shop-redeem") {
    var code = String(body.code || "").trim().toUpperCase();
    if (!/^NYM-[0-9A-F]{32}$/.test(code)) return json({ error: "Invalid recovery code." }, 400);
    var codeData = await codeGet(env.DB_CODES, code);
    if (!codeData) return json({ error: "Unknown recovery code." }, 404);
    var redeemItem = codeData.itemId;
    if (!shopKnown(redeemItem)) return json({ error: "Unknown shop item." }, 400);
    var redeemRes = await ledgerCall(env, {
      op: "shop-redeem", code: code, itemId: redeemItem, user: userPubkey
    });
    if (redeemRes && redeemRes._noLedger) return json({ error: "Service temporarily unavailable." }, 503);
    if (redeemRes && redeemRes.unknown) return json({ error: "Unknown recovery code." }, 404);
    if (!redeemRes || redeemRes.error) return json({ error: (redeemRes && redeemRes.error) || "Redeem failed." }, 400);
    var prevOwner = String(redeemRes.prevOwner || "").toLowerCase();
    if (prevOwner && prevOwner !== userPubkey && /^[0-9a-f]{64}$/.test(prevOwner)) {
      readCacheDelete(context, "/shop-status/" + prevOwner);
    }
    if (redeemRes.alreadyOwner) {
      return json({ itemId: redeemItem, owned: redeemRes.owned, active: redeemRes.active, alreadyOwner: true });
    }
    return json({ itemId: redeemItem, owned: redeemRes.owned, active: redeemRes.active });
  }

  return json({ error: "Unknown action" }, 400);
}

// Categories are client-encrypted (NIP-44) opaque blobs, validated by prefix/charset rather than enumerated.
var SETTINGS_CATEGORY_RE = /^nym(?:chat|bot)-[a-z0-9-]{1,120}$/i;
// Group history adds one category per group per month; the ceiling is only an abuse backstop.
var SETTINGS_MAX_CATEGORIES = 50000;
var SETTINGS_MAX_NYMBOT_CATEGORIES = 1000;
var SETTINGS_MAX_BYTES = 256 * 1024 * 1024;
var SETTINGS_MAX_BLOB = 1900000;
function isValidSettingsCategory(cat) { return SETTINGS_CATEGORY_RE.test(cat); }

async function handleSettingsAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_SETTINGS)) return json({ error: "Settings storage is not configured (missing DB_SETTINGS binding)." }, 503);

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!clientAuthOk(context, body, userPubkey)) return json({ error: "Authentication failed" }, 401);

  if (body.action === "settings-get") {
    var categories = {};
    var now = Date.now();
    var since = body.since;
    var incremental = typeof since === "number" && isFinite(since) && since >= 0;
    var only = Array.isArray(body.only) && body.only.length && body.only.length <= 10 &&
      body.only.every(function (c) { return typeof c === "string" && isValidSettingsCategory(c); })
      ? body.only : null;
    var cursor = null;
    try {
      var rs;
      if (incremental || only) {
        var top = await env.DB_SETTINGS.prepare("SELECT MAX(updated_at) AS m FROM settings WHERE pubkey = ?").bind(userPubkey).first();
        cursor = top && top.m != null ? Number(top.m) || 0 : now;
        var q = "SELECT category, blob, updated_at FROM settings WHERE pubkey = ?";
        var binds = [userPubkey];
        if (incremental) { q += " AND updated_at > ?"; binds.push(Math.floor(since)); }
        if (only) { q += " AND category IN (" + only.map(function () { return "?"; }).join(", ") + ")"; binds = binds.concat(only); }
        rs = await env.DB_SETTINGS.prepare(q).bind(...binds).all();
      } else {
        rs = await env.DB_SETTINGS.prepare("SELECT category, blob, updated_at FROM settings WHERE pubkey = ?").bind(userPubkey).all();
        var rows = rs.results || [];
        cursor = rows.length ? 0 : now;
        rows.forEach(function (r) { cursor = Math.max(cursor, Number(r.updated_at) || 0); });
      }
      (rs.results || []).forEach(function (r) {
        if (isValidSettingsCategory(r.category) && typeof r.blob === "string") {
          categories[r.category] = { blob: r.blob, updatedAt: r.updated_at || 0 };
        }
      });
    } catch (e) {
      return json({ categories: {} });
    }
    return json({ categories: categories, cursor: cursor, now: now, full: !incremental && !only });
  }

  if (body.action === "settings-set") {
    var cat = String(body.category || "");
    if (!isValidSettingsCategory(cat)) return json({ error: "Unknown settings category." }, 400);
    if (typeof body.blob !== "string" || !body.blob) return json({ error: "Missing settings blob." }, 400);
    if (body.blob.length > SETTINGS_MAX_BLOB) return json({ error: "Settings payload too large." }, 413);
    var contentHash = (typeof body.contentHash === "string" && /^[0-9a-f]{64}$/i.test(body.contentHash))
      ? body.contentHash.toLowerCase() : null;
    var prevDoc = null;
    try {
      prevDoc = await env.DB_SETTINGS.prepare("SELECT content_hash, updated_at, LENGTH(blob) AS len FROM settings WHERE pubkey = ? AND category = ?").bind(userPubkey, cat).first();
    } catch (e) { }
    if (contentHash && prevDoc && prevDoc.content_hash === contentHash) {
      return json({ ok: true, category: cat, updatedAt: prevDoc.updated_at || 0, unchanged: true });
    }
    // Cap distinct categories per user to bound storage from runaway splitting.
    var prevLen = prevDoc ? (Number(prevDoc.len) || 0) : 0;
    if (!prevDoc || body.blob.length > prevLen) {
      try {
        var cntRow = await env.DB_SETTINGS.prepare(
          "SELECT COUNT(*) AS n, SUM(LENGTH(blob)) AS bytes, SUM(CASE WHEN category LIKE 'nymbot-%' THEN 1 ELSE 0 END) AS bot FROM settings WHERE pubkey = ?"
        ).bind(userPubkey).first();
        if (!prevDoc && cntRow && (cntRow.n || 0) >= SETTINGS_MAX_CATEGORIES) {
          return json({ error: "Too many settings categories." }, 429);
        }
        if (!prevDoc && cntRow && /^nymbot-/i.test(cat) && (cntRow.bot || 0) >= SETTINGS_MAX_NYMBOT_CATEGORIES) {
          return json({ error: "Too many settings categories." }, 429);
        }
        if (cntRow && (Number(cntRow.bytes) || 0) - prevLen + body.blob.length > SETTINGS_MAX_BYTES) {
          return json({ error: "Settings storage is full." }, 413);
        }
      } catch (e) { }
    }
    var updatedAt = Date.now();
    var baseHash = typeof body.baseHash === "string" && (body.baseHash === "" || /^[0-9a-f]{64}$/i.test(body.baseHash))
      ? body.baseHash.toLowerCase() : null;
    if (baseHash != null) {
      var swapped = baseHash === ""
        ? await env.DB_SETTINGS.prepare(
          "INSERT INTO settings (pubkey, category, blob, content_hash, updated_at) VALUES (?, ?, ?, ?, ?) " +
          "ON CONFLICT(pubkey, category) DO NOTHING"
        ).bind(userPubkey, cat, body.blob, contentHash, updatedAt).run()
        : await env.DB_SETTINGS.prepare(
          "UPDATE settings SET blob = ?, content_hash = ?, updated_at = ? WHERE pubkey = ? AND category = ? AND content_hash = ?"
        ).bind(body.blob, contentHash, updatedAt, userPubkey, cat, baseHash).run();
      if (!(swapped && swapped.meta && Number(swapped.meta.changes) > 0)) {
        var nowDoc = null;
        try {
          nowDoc = await env.DB_SETTINGS.prepare("SELECT content_hash, updated_at FROM settings WHERE pubkey = ? AND category = ?").bind(userPubkey, cat).first();
        } catch (e) { }
        return json({
          error: "These settings changed on another device. Fetch them, merge, and save again.",
          conflict: true, category: cat,
          contentHash: nowDoc ? (nowDoc.content_hash || null) : null,
          updatedAt: nowDoc ? (nowDoc.updated_at || 0) : 0
        }, 409);
      }
      return json({ ok: true, category: cat, updatedAt: updatedAt });
    }
    await env.DB_SETTINGS.prepare(
      "INSERT INTO settings (pubkey, category, blob, content_hash, updated_at) VALUES (?, ?, ?, ?, ?) " +
      "ON CONFLICT(pubkey, category) DO UPDATE SET blob = excluded.blob, content_hash = excluded.content_hash, updated_at = excluded.updated_at"
    ).bind(userPubkey, cat, body.blob, contentHash, updatedAt).run();
    return json({ ok: true, category: cat, updatedAt: updatedAt });
  }

  return json({ error: "Unknown action" }, 400);
}

// Scoped by app; credits, shop items, the free-tier counter and zap receipts deliberately survive a wipe.
async function handleAccountAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };

  if (body.action !== "account-purge") return json({ error: "Unknown action" }, 400);

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!clientAuthOk(context, body, userPubkey)) return json({ error: "Authentication failed" }, 401);

  var app = String(body.app || "nymchat").toLowerCase();
  if (app !== "nymchat" && app !== "nymbot") return json({ error: "Unknown app" }, 400);

  var removed = { settings: 0, profile: 0, pm: 0 };
  var changes = function (r) { return (r && r.meta && r.meta.changes) || 0; };

  if (hasD1(env.DB_SETTINGS)) {
    try {
      var sql = app === "nymbot"
        ? "DELETE FROM settings WHERE pubkey = ? AND category LIKE 'nymbot-%'"
        : "DELETE FROM settings WHERE pubkey = ? AND category NOT LIKE 'nymbot-%'";
      removed.settings = changes(await env.DB_SETTINGS.prepare(sql).bind(userPubkey).run());
    } catch (e) { }
  }

  if (app === "nymbot") {
    var purgeRows = async function (db, table) {
      if (!hasD1(db)) return 0;
      try { return changes(await db.prepare("DELETE FROM " + table + " WHERE pubkey = ?").bind(userPubkey).run()); } catch (e) { return 0; }
    };
    removed.apiKeys = await purgeRows(env.DB_CREDITS, "api_keys");
    removed.apiNwc = await purgeRows(env.DB_CREDITS, "api_nwc");
    removed.apiQueries = await purgeRows(env.DB_BOT, "api_queries");
    removed.apiVideoJobs = await purgeRows(env.DB_BOT, "api_video_jobs");
    removed.usage = await purgeRows(env.DB_BOT, "bot_usage");
    try {
      var bgCleared = await bgDriver(env, userPubkey, { drive: "clear" });
      if (bgCleared) removed.schedules = Number(bgCleared.deleted) || 0;
    } catch (e) { }
    if (hasD1(env.DB_CREDITS)) {
      for (var tier of ["standard", "pro"]) {
        try { await apiDebtCollect(env, userPubkey, tier); } catch (e) { }
      }
    }
  }

  if (app === "nymchat") {
    if (hasD1(env.DB_PROFILES)) {
      try {
        removed.profile = changes(await env.DB_PROFILES.prepare(
          "DELETE FROM profiles WHERE pubkey = ?").bind(userPubkey).run());
      } catch (e) { }
    }
    if (hasD1(env.DB_PM)) {
      try {
        removed.pm = changes(await env.DB_PM.prepare(
          "DELETE FROM pm WHERE pubkey = ?").bind(userPubkey).run());
      } catch (e) { }
    }
  }

  return json({ ok: true, app: app, removed: removed });
}

// Stored as the signed event so clients can verify and reconcile by created_at.
var PROFILE_MAX_EVENT = 64 * 1024;

function profileIsValidEvent(ev, pubkey) {
  try {
    if (!ev || typeof ev !== "object") return false;
    if (ev.kind !== 0 || ev.pubkey !== pubkey) return false;
    if (typeof ev.content !== "string" || typeof ev.id !== "string" || typeof ev.sig !== "string") return false;
    if (getEventHash(ev) !== ev.id) return false;
    return schnorr.verify(ev.sig, ev.id, ev.pubkey);
  } catch (e) {
    return false;
  }
}

async function handleProfileAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_PROFILES)) return json({ error: "Profile storage is not configured (missing DB_PROFILES binding)." }, 503);

  // Per-pubkey edge cache: hits skip D1, misses read from a replica.
  if (body.action === "profile-get") {
    var rawPks = Array.isArray(body.pubkeys) ? body.pubkeys.slice(0, 100) : [];
    var pks = [];
    for (var i = 0; i < rawPks.length; i++) {
      var pk = rawPks[i];
      if (typeof pk === "string" && /^[0-9a-f]{64}$/i.test(pk)) pks.push(pk.toLowerCase());
    }
    var cacheLookups = await Promise.all(pks.map(async function (pk) {
      var cached = await readCacheGet("/profile/" + pk);
      return [pk, cached];
    }));
    var cachedRecs = {};
    var misses = [];
    cacheLookups.forEach(function (pair) {
      if (pair[1] !== null) cachedRecs[pair[0]] = pair[1].rec || null;
      else misses.push(pair[0]);
    });
    var freshRecs = {};
    if (misses.length) {
      try {
        var ph = misses.map(function () { return "?"; }).join(",");
        var rs = await replica(env.DB_PROFILES).prepare("SELECT pubkey, event, updated_at FROM profiles WHERE pubkey IN (" + ph + ")").bind(...misses).all();
        (rs.results || []).forEach(function (r) {
          var ev = null;
          try { ev = JSON.parse(r.event); } catch (e) { ev = null; }
          if (ev) freshRecs[r.pubkey] = { event: ev, updatedAt: r.updated_at || 0 };
        });
      } catch (e) { }
    }
    var profEncoder = new TextEncoder();
    var profStream = new ReadableStream({
      start(controller) {
        pks.forEach(function (pk) {
          var rec;
          if (Object.prototype.hasOwnProperty.call(cachedRecs, pk)) {
            rec = cachedRecs[pk];
          } else {
            rec = freshRecs[pk] || null;
            readCachePut(context, "/profile/" + pk, { rec: rec }, PROFILE_READ_TTL);
          }
          controller.enqueue(profEncoder.encode(JSON.stringify([pk, rec]) + "\n"));
        });
        try { controller.close(); } catch (_) { }
      }
    });
    return new Response(profStream, {
      status: 200,
      headers: { "Content-Type": "application/x-ndjson", ...CLIENT_CORS_HEADERS }
    });
  }

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!clientAuthOk(context, body, userPubkey)) return json({ error: "Authentication failed" }, 401);

  if (body.action === "profile-set") {
    var ev = body.event;
    if (!profileIsValidEvent(ev, userPubkey)) return json({ error: "Invalid profile event." }, 400);
    if (JSON.stringify(ev).length > PROFILE_MAX_EVENT) return json({ error: "Profile too large." }, 413);
    // Keep only the newest profile, ordered by the event's own created_at.
    try {
      var prev = await env.DB_PROFILES.prepare("SELECT created_at, updated_at FROM profiles WHERE pubkey = ?").bind(userPubkey).first();
      if (prev && (prev.created_at || 0) >= (ev.created_at || 0)) {
        return json({ ok: true, updatedAt: prev.updated_at || 0, stale: true });
      }
    } catch (e) { }
    var updatedAt = Date.now();
    await env.DB_PROFILES.prepare(
      "INSERT INTO profiles (pubkey, created_at, updated_at, event) VALUES (?, ?, ?, ?) " +
      "ON CONFLICT(pubkey) DO UPDATE SET created_at = excluded.created_at, updated_at = excluded.updated_at, event = excluded.event"
    ).bind(userPubkey, ev.created_at || 0, updatedAt, JSON.stringify(ev)).run();
    // Refresh the edge cache so the new profile is served immediately.
    readCachePut(context, "/profile/" + userPubkey, { rec: { event: ev, updatedAt: updatedAt } }, PROFILE_READ_TTL);
    return json({ ok: true, updatedAt: updatedAt });
  }

  return json({ error: "Unknown action" }, 400);
}

var PM_EVENT_MAX = 96 * 1024;
var CHANNEL_EVENT_MAX = 64 * 1024;
var CHANNEL_TTL_MS = 24 * 60 * 60 * 1000;
var CHANNEL_FUTURE_SKEW_S = 600;
var ZAP_EVENT_MAX = 32 * 1024;

// Read-through per-colo edge cache for PUBLIC reads only.
var READ_CACHE_HOST = "https://nymchat-read.invalid";
var CHANNEL_READ_TTL = 45;
var PROFILE_READ_TTL = 300;
var SHOP_READ_TTL = 300;
function readCacheRequest(path) {
  return new Request(READ_CACHE_HOST + path, { method: "GET" });
}
async function readCacheGet(path) {
  try {
    var hit = await caches.default.match(readCacheRequest(path));
    if (!hit) return null;
    return await hit.json();
  } catch (e) { return null; }
}
function readCachePut(context, path, obj, ttlSeconds) {
  try {
    var headers = new Headers();
    headers.set("Content-Type", "application/json");
    headers.set("Cache-Control", "public, max-age=" + (ttlSeconds || 60));
    var op = caches.default.put(readCacheRequest(path), new Response(JSON.stringify(obj), { headers: headers }));
    if (context && context.waitUntil) context.waitUntil(op);
  } catch (e) { }
}
async function readCacheGetRaw(path) {
  try {
    var hit = await caches.default.match(readCacheRequest(path));
    if (!hit) return null;
    return await hit.text();
  } catch (e) { return null; }
}
function readCachePutRaw(context, path, bodyText, contentType, ttlSeconds) {
  try {
    var headers = new Headers();
    headers.set("Content-Type", contentType || "text/plain");
    headers.set("Cache-Control", "public, max-age=" + (ttlSeconds || 60));
    var op = caches.default.put(readCacheRequest(path), new Response(bodyText, { headers: headers }));
    if (context && context.waitUntil) context.waitUntil(op);
  } catch (e) { }
}
var STORAGE_RATE_HOST = "https://nymchat-rate.invalid";
var PM_DEPOSIT_RATE = 600;
var PM_DEPOSIT_IP_RATE = 3000;
var ZAP_PUT_RATE = 300;
var STORAGE_RATE_WINDOW_MS = 60000;

function storageRequestIp(context) {
  try {
    var h = context && context.request && context.request.headers;
    return (h && typeof h.get === "function" && h.get("CF-Connecting-IP")) || "";
  } catch (e) { return ""; }
}

async function storageRateTake(bucket, who, units, limit) {
  try {
    if (typeof caches === "undefined" || !caches.default || !who) return true;
    var windowId = Math.floor(Date.now() / STORAGE_RATE_WINDOW_MS);
    var key = new Request(STORAGE_RATE_HOST + "/" + bucket + "?k=" + encodeURIComponent(who) + "&w=" + windowId, { method: "GET" });
    var count = 0;
    var hit = await caches.default.match(key);
    if (hit) {
      var n = parseInt(await hit.text(), 10);
      if (Number.isFinite(n)) count = n;
    }
    if (count + units > limit) return false;
    await caches.default.put(key, new Response(String(count + units), {
      headers: { "Content-Type": "text/plain", "Cache-Control": "max-age=" + Math.ceil(STORAGE_RATE_WINDOW_MS / 1000) }
    }));
    return true;
  } catch (e) {
    return true;
  }
}

function readCacheDelete(context, path) {
  try {
    var op = caches.default.delete(readCacheRequest(path));
    if (context && context.waitUntil) context.waitUntil(op);
  } catch (e) { }
}

// Channel names become D1 row keys; keep them to a safe, bounded charset.
function archiveSanitizeChannel(name) {
  if (typeof name !== "string") return "";
  return name.trim().toLowerCase().replace(/[^\p{L}\p{N}_\-.]/gu, "").slice(0, 80);
}

async function spamAwareActivityRows(db, innerWhere, binds, limit) {
  var lim = limit ? (" LIMIT " + limit) : "";
  var spamSql = "SELECT channel, age, COUNT(*) AS c, MAX(mx) AS mx FROM (" +
    "SELECT channel, CAST((? - created_at) / 3600 AS INTEGER) AS age, created_at AS mx, " +
    "COUNT(*) OVER (PARTITION BY pubkey) AS pk FROM events WHERE " + innerWhere + ") " +
    "WHERE pk >= 2 GROUP BY channel, age" + lim;
  try {
    return (await db.prepare(spamSql).bind(...binds).all()).results || [];
  } catch (e) {
    var plainSql = "SELECT channel, CAST((? - created_at) / 3600 AS INTEGER) AS age, " +
      "COUNT(*) AS c, MAX(created_at) AS mx FROM events WHERE " + innerWhere +
      " GROUP BY channel, age" + lim;
    try {
      return (await db.prepare(plainSql).bind(...binds).all()).results || [];
    } catch (e2) { return []; }
  }
}

function buildActivityResult(rows) {
  var activity = {};
  var last = {};
  (rows || []).forEach(function (r) {
    if (r.mx && r.mx > (last[r.channel] || 0)) last[r.channel] = r.mx;
    var ageH = r.age;
    if (ageH < 0 || ageH >= 24) return;
    var b = activity[r.channel];
    if (!b) { b = new Array(24).fill(0); activity[r.channel] = b; }
    b[ageH] = r.c || 0;
  });
  return { activity: activity, last: last };
}

async function topChannelActivityRows(db, kind, now, minTs, channelLimit) {
  var seen = "(SELECT channel, created_at, COUNT(*) OVER (PARTITION BY pubkey) AS pk " +
    "FROM events WHERE kind = ? AND created_at >= ?)";
  var spamSql =
    "SELECT pb.channel AS channel, pb.age AS age, pb.c AS c, pb.mx AS mx FROM (" +
    "SELECT channel, CAST((? - created_at) / 3600 AS INTEGER) AS age, COUNT(*) AS c, MAX(created_at) AS mx " +
    "FROM " + seen + " WHERE pk >= 2 GROUP BY channel, age" +
    ") pb JOIN (" +
    "SELECT channel FROM " + seen + " WHERE pk >= 2 " +
    "GROUP BY channel ORDER BY COUNT(*) DESC, channel LIMIT ?" +
    ") top ON pb.channel = top.channel";
  try {
    return (await db.prepare(spamSql).bind(now, kind, minTs, kind, minTs, channelLimit).all()).results || [];
  } catch (e) {
    var plainSql =
      "SELECT pb.channel AS channel, pb.age AS age, pb.c AS c, pb.mx AS mx FROM (" +
      "SELECT channel, CAST((? - created_at) / 3600 AS INTEGER) AS age, COUNT(*) AS c, MAX(created_at) AS mx " +
      "FROM events WHERE kind = ? AND created_at >= ? GROUP BY channel, age" +
      ") pb JOIN (" +
      "SELECT channel FROM events WHERE kind = ? AND created_at >= ? " +
      "GROUP BY channel ORDER BY COUNT(*) DESC, channel LIMIT ?" +
      ") top ON pb.channel = top.channel";
    try {
      return (await db.prepare(plainSql).bind(now, kind, minTs, kind, minTs, channelLimit).all()).results || [];
    } catch (e2) { return []; }
  }
}

// Storable only if a valid kind 1059/1060 event addressed to that user via a `p` tag.
function pmIsValidWrapForUser(ev, pubkey) {
  try {
    if (!ev || typeof ev !== "object") return false;
    if (ev.kind !== 1059 && ev.kind !== 1060) return false;
    if (typeof ev.id !== "string" || typeof ev.sig !== "string" || typeof ev.pubkey !== "string") return false;
    if (typeof ev.content !== "string" || !Array.isArray(ev.tags)) return false;
    if (ev.tags.some(function (t) { return Array.isArray(t) && t[0] === "d"; })) return false;
    var addressed = ev.tags.some(function (t) {
      return Array.isArray(t) && t[0] === "p" && typeof t[1] === "string" && t[1].toLowerCase() === pubkey;
    });
    if (!addressed) return false;
    if (getEventHash(ev) !== ev.id) return false;
    return schnorr.verify(ev.sig, ev.id, ev.pubkey);
  } catch (e) { return false; }
}

function pmWrapRecipient(ev) {
  if (!ev || !Array.isArray(ev.tags)) return null;
  var p = ev.tags.find(function (t) {
    return Array.isArray(t) && t[0] === "p" && typeof t[1] === "string" && /^[0-9a-f]{64}$/i.test(t[1]);
  });
  return p ? p[1].toLowerCase() : null;
}

async function handlePmAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_PM)) return json({ error: "PM storage is not configured (missing DB_PM binding)." }, 503);

  // No auth needed: wraps are already public-by-recipient on relays and payloads stay encrypted.
  if (body.action === "pm-get" && Array.isArray(body.pubkeys)) {
    var inboxPks = [];
    var seenInbox = {};
    for (var ipi = 0; ipi < body.pubkeys.length && inboxPks.length < 200; ipi++) {
      var ipk = body.pubkeys[ipi];
      if (typeof ipk === "string" && /^[0-9a-f]{64}$/i.test(ipk)) {
        var lipk = ipk.toLowerCase();
        if (!seenInbox[lipk]) { seenInbox[lipk] = 1; inboxPks.push(lipk); }
      }
    }
    var inboxSince = Number(body.since) || 0;
    var inboxLimit = Number(body.limit);
    if (!Number.isFinite(inboxLimit) || inboxLimit <= 0) inboxLimit = 1000;
    if (inboxLimit > 1000) inboxLimit = 1000;
    var inboxRows = [];
    if (inboxPks.length) {
      try {
        var inboxPh = inboxPks.map(function () { return "?"; }).join(",");
        inboxRows = (await replica(env.DB_PM).prepare(
          "SELECT event FROM pm WHERE pubkey IN (" + inboxPh + ") AND created_at >= ? ORDER BY created_at DESC LIMIT ?"
        ).bind(...inboxPks, inboxSince, inboxLimit).all()).results || [];
      } catch (e) { inboxRows = []; }
    }
    var inboxEnc = new TextEncoder();
    var inboxStream = new ReadableStream({
      start(controller) {
        for (var ij = 0; ij < inboxRows.length; ij++) {
          controller.enqueue(inboxEnc.encode(inboxRows[ij].event + "\n"));
        }
        try { controller.close(); } catch (_) { }
      }
    });
    return new Response(inboxStream, {
      status: 200,
      headers: { "Content-Type": "application/x-ndjson", ...CLIENT_CORS_HEADERS }
    });
  }

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!clientAuthOk(context, body, userPubkey)) return json({ error: "Authentication failed" }, 401);

  // Primary key (pubkey, id) makes re-uploads free no-ops via INSERT OR IGNORE.
  if (body.action === "pm-put") {
    var events = Array.isArray(body.events) ? body.events.slice(0, 100)
      : (body.event ? [body.event] : []);
    var now = Date.now();
    var stmt = env.DB_PM.prepare("INSERT OR IGNORE INTO pm (pubkey, id, created_at, event, stored_at) VALUES (?, ?, ?, ?, ?)");
    var batch = [];
    for (var i = 0; i < events.length; i++) {
      var ev = events[i];
      if (!pmIsValidWrapForUser(ev, userPubkey)) continue;
      if (JSON.stringify(ev).length > PM_EVENT_MAX) continue;
      batch.push(stmt.bind(userPubkey, ev.id, ev.created_at || 0, JSON.stringify(ev), now));
    }
    var added = 0;
    if (batch.length) {
      var res = await env.DB_PM.batch(batch);
      res.forEach(function (r) { added += (r.meta && r.meta.changes) || 0; });
    }
    return json({ ok: true, added: added });
  }

  // Keyed by the wrap's `p`-tag recipient, not the sender; the authenticated sender gates anonymous spam.
  if (body.action === "pm-deposit") {
    var depEvents = Array.isArray(body.events) ? body.events.slice(0, 100)
      : (body.event ? [body.event] : []);
    var depNow = Date.now();
    var depUnits = Math.max(1, depEvents.length);
    if (!(await storageRateTake("pm-deposit", userPubkey, depUnits, PM_DEPOSIT_RATE)) ||
      !(await storageRateTake("pm-deposit-ip", storageRequestIp(context), depUnits, PM_DEPOSIT_IP_RATE))) {
      return json({ error: "Too many messages deposited. Try again in a minute." }, 429);
    }
    var depCeil = Math.floor(depNow / 1000);
    var depStmt = env.DB_PM.prepare("INSERT OR IGNORE INTO pm (pubkey, id, created_at, event, stored_at) VALUES (?, ?, ?, ?, ?)");
    var depBatch = [];
    for (var di = 0; di < depEvents.length; di++) {
      var dev = depEvents[di];
      var recipient = pmWrapRecipient(dev);
      if (!recipient || recipient === userPubkey) continue;
      if (JSON.stringify(dev).length > PM_EVENT_MAX) continue;
      if (!pmIsValidWrapForUser(dev, recipient)) continue;
      depBatch.push(depStmt.bind(recipient, dev.id, Math.min(Number(dev.created_at) || 0, depCeil), JSON.stringify(dev), depNow));
    }
    var depAdded = 0;
    if (depBatch.length) {
      var depRes = await env.DB_PM.batch(depBatch);
      depRes.forEach(function (r) { depAdded += (r.meta && r.meta.changes) || 0; });
    }
    return json({ ok: true, added: depAdded });
  }

  if (body.action === "pm-get") {
    var since = Number(body.since) || 0;
    var before = Number(body.before) || 0;
    var limit = Number(body.limit);
    if (!Number.isFinite(limit) || limit <= 0) limit = 1000;
    if (limit > 1000) limit = 1000;
    var sql = "SELECT event FROM pm WHERE pubkey = ? AND created_at >= ?";
    var binds = [userPubkey, since];
    if (before) { sql += " AND created_at < ?"; binds.push(before); }
    sql += " ORDER BY created_at DESC LIMIT ?";
    binds.push(limit);
    var rows = [];
    try { rows = (await replica(env.DB_PM).prepare(sql).bind(...binds).all()).results || []; } catch (e) { rows = []; }
    var hasMore = rows.length >= limit;
    var pmEncoder = new TextEncoder();
    var pmStream = new ReadableStream({
      start(controller) {
        for (var j = 0; j < rows.length; j++) {
          controller.enqueue(pmEncoder.encode(rows[j].event + "\n"));
        }
        try { controller.close(); } catch (_) { }
      }
    });
    return new Response(pmStream, {
      status: 200,
      headers: {
        "Content-Type": "application/x-ndjson",
        "X-Has-More": hasMore ? "1" : "0",
        "Access-Control-Expose-Headers": "X-Has-More",
        ...CLIENT_CORS_HEADERS
      }
    });
  }

  // Rows live under the authenticated user's own pubkey, so ownership is implicit.
  if (body.action === "pm-delete") {
    var delIds = Array.isArray(body.ids) ? body.ids.slice(0, 200) : [];
    var clean = [];
    for (var k = 0; k < delIds.length; k++) {
      var did = delIds[k];
      if (typeof did === "string" && /^[0-9a-f]{64}$/i.test(did)) clean.push(did.toLowerCase());
    }
    var removed = 0;
    if (clean.length) {
      var ph2 = clean.map(function () { return "?"; }).join(",");
      try {
        var dr = await env.DB_PM.prepare("DELETE FROM pm WHERE pubkey = ? AND id IN (" + ph2 + ")").bind(userPubkey, ...clean).run();
        removed = (dr.meta && dr.meta.changes) || 0;
      } catch (e) { }
    }
    return json({ ok: true, removed: removed });
  }

  return json({ error: "Unknown action" }, 400);
}

async function handleChannelAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_CHANNELS)) return json({ error: "Channel storage is not configured (missing DB_CHANNELS binding)." }, 503);

  // Public read of archived events by id, so event details can show the real signed event.
  if (body.action === "event-get") {
    var wantIds = [];
    var seenId = {};
    var rawIds = Array.isArray(body.ids) ? body.ids : [body.id];
    for (var ii = 0; ii < rawIds.length && wantIds.length < 20; ii++) {
      var wid = rawIds[ii];
      if (typeof wid === "string" && /^[0-9a-f]{64}$/.test(wid) && !seenId[wid]) {
        seenId[wid] = 1;
        wantIds.push(wid);
      }
    }
    if (!wantIds.length) return json({ error: "Invalid id." }, 400);
    var idHoles = wantIds.map(function () { return "?"; }).join(",");
    var idStmt = env.DB_CHANNELS
      .prepare("SELECT id, channel, kind, pubkey, created_at, json, stored_at FROM events WHERE id IN (" + idHoles + ")");
    var idRows = await idStmt.bind.apply(idStmt, wantIds).all().catch(function () { return null; });
    var outEvents = [];
    var idList = (idRows && idRows.results) || [];
    for (var ri = 0; ri < idList.length; ri++) {
      var row = idList[ri];
      var parsed = null;
      try { parsed = JSON.parse(row.json); } catch (e) { parsed = null; }
      if (!parsed || parsed.id !== row.id) continue;
      parsed.stored_at = Number(row.stored_at) || 0;
      parsed.archived_channel = row.channel;
      outEvents.push(parsed);
    }
    return json({ events: outEvents });
  }

  // No auth: channels are public and the origin gate already limits this to Nymchat clients.
  if (body.action === "channel-get") {
    var reqChannels = [];
    if (Array.isArray(body.channels)) {
      var seenC = {};
      for (var ci = 0; ci < body.channels.length && reqChannels.length < 50; ci++) {
        var cn = archiveSanitizeChannel(body.channels[ci]);
        if (cn && !seenC[cn]) { seenC[cn] = 1; reqChannels.push(cn); }
      }
    } else {
      var single = archiveSanitizeChannel(body.channel);
      if (single) reqChannels.push(single);
    }
    if (!reqChannels.length) return json({ error: "Invalid channel." }, 400);
    var isSingle = reqChannels.length === 1;
    // Author filter: nym-pq holds one announcement per user, anywhere in the table.
    var reqAuthors = [];
    if (Array.isArray(body.authors)) {
      var seenA = {};
      for (var ai = 0; ai < body.authors.length && reqAuthors.length < 50; ai++) {
        var au = body.authors[ai];
        if (typeof au === "string" && /^[0-9a-f]{64}$/.test(au) && !seenA[au]) {
          seenA[au] = 1; reqAuthors.push(au);
        }
      }
      if (!reqAuthors.length) return json({ error: "Invalid authors." }, 400);
    }
    // PQ announcements are valid seven days but republished daily, so widen the since floor for this channel.
    var ttlMs = (isSingle && reqChannels[0] === "nym-pq")
      ? 7 * 24 * 60 * 60 * 1000 : CHANNEL_TTL_MS;
    var minTsSec = Math.floor((Date.now() - ttlMs) / 1000);
    var since = Number(body.since) || 0;
    var floorSec = since > minTsSec ? since : minTsSec;
    var ndjsonHeaders = { "Content-Type": "application/x-ndjson", ...CLIENT_CORS_HEADERS };
    // Cache only the unfiltered read: the key is the channel alone.
    if (isSingle && !since && !reqAuthors.length) {
      var cachedBody = await readCacheGetRaw("/channel/" + reqChannels[0]);
      if (cachedBody !== null) {
        return new Response(cachedBody, { status: 200, headers: ndjsonHeaders });
      }
    }
    var rows = [];
    try {
      var cph = reqChannels.map(function () { return "?"; }).join(",");
      var authorClause = reqAuthors.length
        ? " AND pubkey IN (" + reqAuthors.map(function () { return "?"; }).join(",") + ")"
        : "";
      rows = (await replica(env.DB_CHANNELS).prepare(
        "SELECT id, kind, json, stored_at FROM events WHERE channel IN (" + cph + ")"
        + authorClause + " AND created_at >= ? AND created_at <= ? ORDER BY created_at DESC LIMIT ?"
      ).bind(...reqChannels, ...reqAuthors, floorSec, Math.floor(Date.now() / 1000) + CHANNEL_FUTURE_SKEW_S, isSingle ? 500 : 1500).all()).results || [];
    } catch (e) { rows = []; }
    var zapRows = [];
    if (rows.length) {
      var targetIds = rows.filter(function (r) {
        return (r.kind === 20000 || r.kind === 23333) && typeof r.id === "string";
      }).map(function (r) { return r.id; });
      if (targetIds.length) {
        try {
          var zph = targetIds.map(function () { return "?"; }).join(",");
          zapRows = (await replica(env.DB_CHANNELS).prepare(
            "SELECT json FROM zaps WHERE target_id IN (" + zph + ") ORDER BY created_at DESC LIMIT 1000"
          ).bind(...targetIds).all()).results || [];
        } catch (e) { zapRows = []; }
      }
    }
    var encoder = new TextEncoder();
    var cacheBuf = (isSingle && !since && !reqAuthors.length) ? [] : null;
    var stream = new ReadableStream({
      start(controller) {
        for (var i = 0; i < rows.length; i++) {
          var evJson = rows[i].json;
          var sa = rows[i].stored_at;
          if (typeof evJson === "string" && typeof sa === "number" && sa > 0 &&
              evJson.charCodeAt(0) === 123 && evJson.charCodeAt(1) !== 125) {
            evJson = '{"stored_at":' + sa + ',' + evJson.slice(1);
          }
          var line = evJson + "\n";
          controller.enqueue(encoder.encode(line));
          if (cacheBuf) cacheBuf.push(line);
        }
        for (var z = 0; z < zapRows.length; z++) {
          var zline = zapRows[z].json + "\n";
          controller.enqueue(encoder.encode(zline));
          if (cacheBuf) cacheBuf.push(zline);
        }
        try { controller.close(); } catch (_) { }
        if (cacheBuf) {
          readCachePutRaw(context, "/channel/" + reqChannels[0], cacheBuf.join(""), "application/x-ndjson", CHANNEL_READ_TTL);
        }
      }
    });
    return new Response(stream, { status: 200, headers: ndjsonHeaders });
  }

  if (body.action === "channel-activity") {
    var reqNames = Array.isArray(body.channels) ? body.channels : [];
    var wanted = [];
    var seenNames = new Set();
    for (var ai = 0; ai < reqNames.length && wanted.length < 200; ai++) {
      var anm = archiveSanitizeChannel(reqNames[ai]);
      if (!anm || seenNames.has(anm)) continue;
      seenNames.add(anm);
      wanted.push(anm);
    }
    var activity = {};
    var lastA = {};
    if (wanted.length === 0) return json({ activity: activity, last: lastA });
    var nowSecA = Math.floor(Date.now() / 1000);
    var minTsA = nowSecA - 24 * 3600;
    var misses = [];
    await Promise.all(wanted.map(async function (anm) {
      var cachedA = await readCacheGet("/channel-activity/" + anm);
      if (cachedA && Array.isArray(cachedA.b) && cachedA.b.length === 24) {
        activity[anm] = cachedA.b;
        if (cachedA.l) lastA[anm] = cachedA.l;
      } else misses.push(anm);
    }));
    if (misses.length) {
      var ph3 = misses.map(function () { return "?"; }).join(",");
      // Only channel messages (20000 geohash, 23333 named) count toward activity.
      var innerWhereA = "channel IN (" + ph3 + ") AND kind IN (20000, 23333) AND created_at >= ?";
      var rowsA = await spamAwareActivityRows(replica(env.DB_CHANNELS), innerWhereA, [nowSecA].concat(misses, [minTsA]), 0);
      var builtA = buildActivityResult(rowsA);
      misses.forEach(function (anm) {
        var b = builtA.activity[anm] || new Array(24).fill(0);
        var l = builtA.last[anm] || 0;
        activity[anm] = b;
        if (l) lastA[anm] = l;
        readCachePut(context, "/channel-activity/" + anm, { b: b, l: l }, CHANNEL_READ_TTL);
      });
    }
    return json({ activity: activity, last: lastA });
  }

  // Recently active geohash channels (kind 20000), 24 hourly buckets each like channel-activity.
  if (body.action === "channel-active") {
    var cachedActive = await readCacheGet("/channel-active");
    if (cachedActive && cachedActive.activity && typeof cachedActive.activity === "object") {
      return json({ activity: cachedActive.activity, last: cachedActive.last || {} });
    }
    var nowSecD = Math.floor(Date.now() / 1000);
    var minTsD = nowSecD - 24 * 3600;
    var rowsD = await topChannelActivityRows(replica(env.DB_CHANNELS), 20000, nowSecD, minTsD, 4000);
    var builtD = buildActivityResult(rowsD);
    readCachePut(context, "/channel-active", { activity: builtD.activity, last: builtD.last }, CHANNEL_READ_TTL);
    return json({ activity: builtD.activity, last: builtD.last });
  }

  // Recently active named channels (kind 23333), same shape as channel-active.
  if (body.action === "channel-active-named") {
    var cachedActiveN = await readCacheGet("/channel-active-named");
    if (cachedActiveN && cachedActiveN.activity && typeof cachedActiveN.activity === "object") {
      return json({ activity: cachedActiveN.activity, last: cachedActiveN.last || {} });
    }
    var nowSecN = Math.floor(Date.now() / 1000);
    var minTsN = nowSecN - 24 * 3600;
    var rowsN = await topChannelActivityRows(replica(env.DB_CHANNELS), 23333, nowSecN, minTsN, 4000);
    var builtN = buildActivityResult(rowsN);
    readCachePut(context, "/channel-active-named", { activity: builtN.activity, last: builtN.last }, CHANNEL_READ_TTL);
    return json({ activity: builtN.activity, last: builtN.last });
  }

  // NIP-09: the signed kind 5 IS the authorization; delete only events whose author is the signer.
  if (body.action === "channel-delete") {
    var name2 = archiveSanitizeChannel(body.channel);
    var del = body.deletionEvent;
    if (!name2) return json({ error: "Invalid channel." }, 400);
    if (!del || del.kind !== 5 || typeof del.id !== "string" || typeof del.sig !== "string"
      || typeof del.pubkey !== "string" || !Array.isArray(del.tags)) {
      return json({ error: "Invalid deletion event." }, 400);
    }
    try {
      if (getEventHash(del) !== del.id || !schnorr.verify(del.sig, del.id, del.pubkey)) {
        return json({ error: "Deletion event failed verification." }, 400);
      }
    } catch (e) { return json({ error: "Deletion event failed verification." }, 400); }
    var targets = del.tags.filter(function (t) { return Array.isArray(t) && t[0] === "e" && typeof t[1] === "string"; })
      .map(function (t) { return t[1].toLowerCase(); }).filter(function (t) { return /^[0-9a-f]{64}$/.test(t); }).slice(0, 100);
    var removed = 0;
    if (targets.length) {
      var ph4 = targets.map(function () { return "?"; }).join(",");
      try {
        var dr2 = await env.DB_CHANNELS.prepare(
          "DELETE FROM events WHERE channel = ? AND pubkey = ? AND id IN (" + ph4 + ")"
        ).bind(name2, del.pubkey, ...targets).run();
        removed = (dr2.meta && dr2.meta.changes) || 0;
      } catch (e) { }
    }
    if (removed) readCacheDelete(context, "/channel/" + name2);
    return json({ ok: true, removed: removed });
  }

  return json({ error: "Unknown action" }, 400);
}

var EMOJI_READ_TTL = 300;

async function handleEmojiAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };
  if (!hasD1(env.DB_CHANNELS)) return json({ error: "Emoji storage is not configured (missing DB_CHANNELS binding)." }, 503);

  if (body.action === "emoji-get") {
    var ndjsonHeaders = { "Content-Type": "application/x-ndjson", ...CLIENT_CORS_HEADERS };
    var userPk = (typeof body.pubkey === "string" && /^[0-9a-f]{64}$/i.test(body.pubkey)) ? body.pubkey.toLowerCase() : null;

    var packsBody = await readCacheGetRaw("/emoji-packs");
    if (packsBody === null) {
      var packRows = [];
      try {
        packRows = (await replica(env.DB_CHANNELS).prepare(
          "SELECT json FROM emoji_packs WHERE kind = 30030 ORDER BY created_at DESC LIMIT 500"
        ).all()).results || [];
      } catch (e) { packRows = []; }
      packsBody = packRows.map(function (r) { return r.json; }).join("\n");
      if (packsBody) packsBody += "\n";
      readCachePutRaw(context, "/emoji-packs", packsBody, "application/x-ndjson", EMOJI_READ_TTL);
    }

    var userLine = "";
    if (userPk) {
      try {
        var urow = await replica(env.DB_CHANNELS).prepare(
          "SELECT json FROM emoji_packs WHERE coord = ?"
        ).bind("10030:" + userPk + ":").first();
        if (urow && urow.json) userLine = urow.json + "\n";
      } catch (e) { userLine = ""; }
    }

    return new Response((packsBody || "") + userLine, { status: 200, headers: ndjsonHeaders });
  }

  return json({ error: "Unknown action" }, 400);
}

var ZAP_FUTURE_SKEW_S = 600;
var ZAP_REQUEST_MAX = 16384;

function zapTagValue(tags, name) {
  var t = Array.isArray(tags) ? tags.find(function (x) { return Array.isArray(x) && x[0] === name && typeof x[1] === "string"; }) : null;
  return t ? t[1] : null;
}

function zapSignedEventOk(ev, kind, nowS) {
  if (!ev || typeof ev !== "object" || ev.kind !== kind) return false;
  if (typeof ev.id !== "string" || typeof ev.sig !== "string" || typeof ev.pubkey !== "string") return false;
  if (!/^[0-9a-f]{64}$/.test(ev.pubkey)) return false;
  if (typeof ev.content !== "string" || !Array.isArray(ev.tags)) return false;
  if (!Number.isSafeInteger(ev.created_at) || ev.created_at < 0 || ev.created_at > nowS + ZAP_FUTURE_SKEW_S) return false;
  if (getEventHash(ev) !== ev.id) return false;
  return schnorr.verify(ev.sig, ev.id, ev.pubkey);
}

function zapBolt11Msats(invoice) {
  if (typeof invoice !== "string" || invoice.length < 16 || invoice.length > 4096) return null;
  var lower = invoice.toLowerCase();
  var sep = lower.lastIndexOf("1");
  if (sep < 4 || !/^[02-9ac-hj-np-z]{6,}$/.test(lower.slice(sep + 1))) return null;
  var m = lower.slice(0, sep).match(/^ln(?:bcrt|bc|tbs|tb|sb)([1-9][0-9]{0,14})([munp]?)$/);
  if (!m) return null;
  var n = BigInt(m[1]);
  var msats;
  if (m[2] === "m") msats = n * 100000000n;
  else if (m[2] === "u") msats = n * 100000n;
  else if (m[2] === "n") msats = n * 100n;
  else if (m[2] === "p") { if (n % 10n !== 0n) return null; msats = n / 10n; }
  else msats = n * 100000000000n;
  return msats > 0n ? msats : null;
}

function zapIsValidReceipt(ev, nowMs) {
  try {
    var nowS = Math.floor((nowMs || Date.now()) / 1000);
    if (!zapSignedEventOk(ev, 9735, nowS)) return false;
    var desc = zapTagValue(ev.tags, "description");
    if (!desc || desc.length > ZAP_REQUEST_MAX) return false;
    var req = JSON.parse(desc);
    if (!zapSignedEventOk(req, 9734, nowS)) return false;
    var reqP = zapTagValue(req.tags, "p");
    var recP = zapTagValue(ev.tags, "p");
    if (!reqP || !recP || !/^[0-9a-f]{64}$/i.test(reqP) || reqP.toLowerCase() !== recP.toLowerCase()) return false;
    var names = ["e", "a"];
    for (var i = 0; i < names.length; i++) {
      var recV = zapTagValue(ev.tags, names[i]);
      if (recV === null) continue;
      var reqV = zapTagValue(req.tags, names[i]);
      if (reqV === null || (names[i] === "e" ? reqV.toLowerCase() !== recV.toLowerCase() : reqV !== recV)) return false;
    }
    var zapper = zapTagValue(ev.tags, "P");
    if (zapper !== null && zapper.toLowerCase() !== req.pubkey) return false;
    var msats = zapBolt11Msats(zapTagValue(ev.tags, "bolt11"));
    if (msats === null) return false;
    var amount = zapTagValue(req.tags, "amount");
    if (amount !== null) {
      if (!/^[1-9][0-9]{0,18}$/.test(amount) || BigInt(amount) !== msats) return false;
    }
    return true;
  } catch (e) { return false; }
}

var ZAP_LNURL_TIMEOUT_MS = 4000;
var ZAP_LNURL_MAX_BYTES = 65536;
var ZAP_LNURL_MAX_REDIRECTS = 3;
var ZAP_LNURL_TTL_S = 600;
var ZAP_LNURL_MISS_TTL_S = 60;
var ZAP_LNURL_MAX_LOOKUPS = 20;
var ZAP_LNURL_MEMO_MAX = 2000;
var zapLnurlMemo = new Map();
var BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

function zapBech32Lnurl(raw) {
  var s = String(raw || "").trim().toLowerCase();
  if (s.indexOf("lightning:") === 0) s = s.slice(10);
  var sep = s.lastIndexOf("1");
  if (s.slice(0, sep) !== "lnurl" || s.length > 2048 || s.length - sep < 8) return null;
  var words = [];
  for (var i = sep + 1; i < s.length; i++) {
    var v = BECH32_CHARSET.indexOf(s.charAt(i));
    if (v === -1) return null;
    words.push(v);
  }
  words = words.slice(0, -6);
  var acc = 0;
  var bits = 0;
  var bytes = [];
  for (var j = 0; j < words.length; j++) {
    acc = (acc << 5) | words[j];
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      bytes.push((acc >> bits) & 0xff);
    }
    acc &= (1 << bits) - 1;
  }
  try { return new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array(bytes)); } catch (e) { return null; }
}

function zapLnurlSafe(url) {
  var u;
  try { u = new URL(url); } catch (e) { return null; }
  if (u.protocol !== "https:" || u.username || u.password) return null;
  if (u.port && u.port !== "443") return null;
  if (mcpHostBlocked(u.hostname) !== "") return null;
  u.hash = "";
  return u.toString();
}

function zapLnurlFromProfile(ev) {
  if (!ev || typeof ev.content !== "string") return null;
  var meta;
  try { meta = JSON.parse(ev.content); } catch (e) { return null; }
  if (!meta || typeof meta !== "object") return null;
  var lud16 = typeof meta.lud16 === "string" ? meta.lud16.trim().toLowerCase() : "";
  var m = /^([a-z0-9._+-]{1,64})@([a-z0-9.-]{1,253})$/.exec(lud16);
  if (m) return zapLnurlSafe("https://" + m[2] + "/.well-known/lnurlp/" + encodeURIComponent(m[1]));
  if (typeof meta.lud06 === "string") {
    var decoded = zapBech32Lnurl(meta.lud06);
    if (decoded) return zapLnurlSafe(decoded);
  }
  return null;
}

async function zapRecipientProfileStored(env, pubkey) {
  var cached = await readCacheGet("/profile/" + pubkey);
  if (cached && cached.rec && cached.rec.event) return cached.rec.event;
  if (!hasD1(env.DB_PROFILES)) return null;
  try {
    var row = await replica(env.DB_PROFILES).prepare("SELECT event FROM profiles WHERE pubkey = ?").bind(pubkey).first();
    var ev = row && typeof row.event === "string" ? JSON.parse(row.event) : null;
    return ev && ev.pubkey === pubkey && ev.kind === 0 ? ev : null;
  } catch (e) { return null; }
}

var ZAP_PROFILE_RELAY_TIMEOUT_MS = 2500;
var zapRelayProfileMemo = new Map();

function zapFetchRelayProfiles(pubkey, relays, timeoutMs) {
  var filter = { kinds: [0], authors: [pubkey], limit: 3 };
  function fromRelay(url) {
    return new Promise(function (resolve) {
      var out = [];
      var done = false;
      var ws;
      var timer;
      function finish() {
        if (done) return;
        done = true;
        clearTimeout(timer);
        try { ws.close(); } catch (e) { }
        resolve(out);
      }
      try { ws = new WebSocket(url); } catch (e) { resolve(out); return; }
      timer = setTimeout(finish, timeoutMs);
      ws.addEventListener("open", function () {
        try { ws.send(JSON.stringify(["REQ", "zp-" + bytesToHex(crypto.getRandomValues(new Uint8Array(4))), filter])); }
        catch (e) { finish(); }
      });
      ws.addEventListener("message", function (msg) {
        try {
          var data = JSON.parse(msg.data);
          if (Array.isArray(data)) {
            if (data[0] === "EVENT" && data[2] && out.length < 10) out.push(data[2]);
            else if (data[0] === "EOSE") finish();
          }
        } catch (e) { }
      });
      ws.addEventListener("error", finish);
      ws.addEventListener("close", finish);
    });
  }
  return Promise.all((relays || []).map(fromRelay)).then(function (lists) {
    var all = [];
    for (var i = 0; i < lists.length; i++) all = all.concat(lists[i]);
    return all;
  }).catch(function () { return []; });
}

async function zapRecipientRelayProfile(context, pubkey) {
  var now = Date.now();
  var memo = zapRelayProfileMemo.get(pubkey);
  if (memo && memo.exp > now) return memo.ev;
  var key = "/zap-profile/" + pubkey;
  var edge = await readCacheGet(key);
  var newest = null;
  if (edge && Object.prototype.hasOwnProperty.call(edge, "ev")) {
    newest = edge.ev && profileIsValidEvent(edge.ev, pubkey) ? edge.ev : null;
  } else {
    var events = await zapFetchRelayProfiles(pubkey, STORAGE_PQ_RELAYS, ZAP_PROFILE_RELAY_TIMEOUT_MS);
    for (var i = 0; i < events.length; i++) {
      var ev = events[i];
      if (!ev || ev.kind !== 0 || ev.pubkey !== pubkey) continue;
      if (newest && (ev.created_at || 0) <= (newest.created_at || 0)) continue;
      if (JSON.stringify(ev).length > PROFILE_MAX_EVENT) continue;
      if (!profileIsValidEvent(ev, pubkey)) continue;
      newest = ev;
    }
    readCachePut(context, key, { ev: newest }, newest ? ZAP_LNURL_TTL_S : ZAP_LNURL_MISS_TTL_S);
  }
  if (zapRelayProfileMemo.size >= ZAP_LNURL_MEMO_MAX) zapRelayProfileMemo.delete(zapRelayProfileMemo.keys().next().value);
  zapRelayProfileMemo.set(pubkey, { ev: newest, exp: now + (newest ? ZAP_LNURL_TTL_S : ZAP_LNURL_MISS_TTL_S) * 1000 });
  return newest;
}

async function zapRecipientProfile(context, pubkey) {
  var stored = await zapRecipientProfileStored(context.env || {}, pubkey);
  if (stored && zapLnurlFromProfile(stored)) return stored;
  var fromRelays = await zapRecipientRelayProfile(context, pubkey);
  if (fromRelays && zapLnurlFromProfile(fromRelays)) return fromRelays;
  return stored;
}

async function zapLnurlFetchNostrPubkey(url) {
  var controller = new AbortController();
  var timer = setTimeout(function () { controller.abort(); }, ZAP_LNURL_TIMEOUT_MS);
  try {
    var at = url;
    var resp = null;
    for (var hop = 0; hop <= ZAP_LNURL_MAX_REDIRECTS; hop++) {
      resp = await fetch(at, { headers: { "Accept": "application/json" }, redirect: "manual", signal: controller.signal });
      if (!(resp.status >= 300 && resp.status < 400)) break;
      var loc = resp.headers.get("Location");
      try { if (resp.body && resp.body.cancel) await resp.body.cancel(); } catch (e) { }
      if (!loc || hop === ZAP_LNURL_MAX_REDIRECTS) return "";
      var next = zapLnurlSafe(new URL(loc, at).toString());
      if (!next) return "";
      at = next;
    }
    if (!resp || !resp.ok) return "";
    var declared = Number(resp.headers.get("Content-Length")) || 0;
    if (declared > ZAP_LNURL_MAX_BYTES) return "";
    var text = "";
    if (resp.body && resp.body.getReader) {
      var reader = resp.body.getReader();
      var decoder = new TextDecoder();
      var total = 0;
      while (true) {
        var r = await reader.read();
        if (r.done) break;
        total += r.value.length;
        if (total > ZAP_LNURL_MAX_BYTES) {
          try { await reader.cancel(); } catch (e) { }
          return "";
        }
        text += decoder.decode(r.value, { stream: true });
      }
      text += decoder.decode();
    } else {
      text = await resp.text();
      if (text.length > ZAP_LNURL_MAX_BYTES) return "";
    }
    var data = JSON.parse(text);
    if (!data || data.allowsNostr !== true || typeof data.nostrPubkey !== "string") return "";
    var npk = data.nostrPubkey.toLowerCase();
    return /^[0-9a-f]{64}$/.test(npk) ? npk : "";
  } catch (e) {
    return "";
  } finally {
    clearTimeout(timer);
  }
}

async function zapProviderPubkey(context, recipient) {
  var profile = await zapRecipientProfile(context, recipient);
  var url = zapLnurlFromProfile(profile);
  if (!url) return "";
  var now = Date.now();
  var memo = zapLnurlMemo.get(url);
  if (memo && memo.exp > now) return memo.pk;
  var key = "/zap-lnurl/" + bytesToHex(sha256(utf8ToBytes(url)));
  var edge = await readCacheGet(key);
  var pk;
  if (edge && typeof edge.pk === "string") {
    pk = edge.pk;
  } else {
    pk = await zapLnurlFetchNostrPubkey(url);
    readCachePut(context, key, { pk: pk }, pk ? ZAP_LNURL_TTL_S : ZAP_LNURL_MISS_TTL_S);
  }
  if (zapLnurlMemo.size >= ZAP_LNURL_MEMO_MAX) zapLnurlMemo.delete(zapLnurlMemo.keys().next().value);
  zapLnurlMemo.set(url, { pk: pk, exp: now + (pk ? ZAP_LNURL_TTL_S : ZAP_LNURL_MISS_TTL_S) * 1000 });
  return pk;
}

async function zapFilterByProvider(context, candidates) {
  var recipients = [];
  candidates.forEach(function (c) {
    var r = zapRecipientPubkey(c.ev);
    c.recipient = r;
    if (r && recipients.indexOf(r) === -1 && recipients.length < ZAP_LNURL_MAX_LOOKUPS) recipients.push(r);
  });
  var providers = new Map();
  await Promise.all(recipients.map(async function (r) {
    providers.set(r, await zapProviderPubkey(context, r));
  }));
  return candidates.filter(function (c) {
    var want = c.recipient ? providers.get(c.recipient) : "";
    return !!want && String(c.ev.pubkey).toLowerCase() === want;
  });
}

function zapTargetId(ev) {
  var tags = ev.tags || [];
  var e = tags.find(function (t) {
    return Array.isArray(t) && t[0] === "e" && typeof t[1] === "string" && /^[0-9a-f]{64}$/i.test(t[1]);
  });
  if (e) return e[1].toLowerCase();
  var d = tags.find(function (t) { return Array.isArray(t) && t[0] === "description" && typeof t[1] === "string"; });
  if (d) {
    try {
      var req = JSON.parse(d[1]);
      if (req && Array.isArray(req.tags)) {
        var re = req.tags.find(function (t) {
          return Array.isArray(t) && t[0] === "e" && typeof t[1] === "string" && /^[0-9a-f]{64}$/i.test(t[1]);
        });
        if (re) return re[1].toLowerCase();
      }
    } catch (e2) { }
  }
  return null;
}

function zapScopeFromDescription(ev) {
  var d = (ev.tags || []).find(function (t) { return Array.isArray(t) && t[0] === "description" && typeof t[1] === "string"; });
  if (!d) return null;
  var req;
  try { req = JSON.parse(d[1]); } catch (e) { return null; }
  if (!req || !Array.isArray(req.tags)) return null;
  var k = req.tags.find(function (t) { return Array.isArray(t) && t[0] === "k"; });
  if (!k || typeof k[1] !== "string") return null;
  if (k[1] === "20000" || k[1] === "23333") return "channel";
  if (k[1] === "1059") return "pm";
  if (k[1] === "0") return "profile";
  return null;
}

// Profile zaps carry no e tag; they key on the recipient (p tag) pubkey.
function zapRecipientPubkey(ev) {
  var p = (ev.tags || []).find(function (t) {
    return Array.isArray(t) && t[0] === "p" && typeof t[1] === "string" && /^[0-9a-f]{64}$/i.test(t[1]);
  });
  return p ? p[1].toLowerCase() : null;
}

function zapClassify(ev) {
  var scope = zapScopeFromDescription(ev);
  if (!scope) return null;
  var targetId = scope === "profile" ? zapRecipientPubkey(ev) : zapTargetId(ev);
  if (!targetId) return null;
  return { scope: scope, targetId: targetId };
}

async function zapInsert(db, rows, now) {
  if (!hasD1(db) || rows.length === 0) return 0;
  var stmt = db.prepare("INSERT OR IGNORE INTO zaps (id, target_id, pubkey, created_at, json, stored_at) VALUES (?, ?, ?, ?, ?, ?)");
  var batch = rows.map(function (r) {
    return stmt.bind(r.ev.id, r.targetId, typeof r.ev.pubkey === "string" ? r.ev.pubkey : null, r.ev.created_at || 0, JSON.stringify(r.ev), now);
  });
  var added = 0;
  try {
    var res = await db.batch(batch);
    res.forEach(function (x) { added += (x.meta && x.meta.changes) || 0; });
  } catch (e) { }
  return added;
}

async function handleZapAction(context, body) {
  var env = context.env;
  var json = function (obj, status) {
    return new Response(JSON.stringify(obj), {
      status: status || 200,
      headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  };

  if (body.action === "zap-get") {
    var scope = body.scope === "pm" ? "pm" : "channel";
    var db = scope === "pm" ? env.DB_PM : env.DB_CHANNELS;
    var rawIds = Array.isArray(body.ids) ? body.ids : [];
    var ids = [];
    var seen = new Set();
    for (var i = 0; i < rawIds.length && ids.length < 500; i++) {
      var id = rawIds[i];
      if (typeof id === "string" && /^[0-9a-f]{64}$/i.test(id)) {
        var lo = id.toLowerCase();
        if (!seen.has(lo)) { seen.add(lo); ids.push(lo); }
      }
    }
    var rows = [];
    if (ids.length && hasD1(db)) {
      try {
        var ph = ids.map(function () { return "?"; }).join(",");
        rows = (await replica(db).prepare(
          "SELECT json FROM zaps WHERE target_id IN (" + ph + ") ORDER BY created_at DESC LIMIT 1000"
        ).bind(...ids).all()).results || [];
      } catch (e) { rows = []; }
    }
    var zapEncoder = new TextEncoder();
    var zapStream = new ReadableStream({
      start(controller) {
        for (var j = 0; j < rows.length; j++) {
          controller.enqueue(zapEncoder.encode(rows[j].json + "\n"));
        }
        try { controller.close(); } catch (_) { }
      }
    });
    return new Response(zapStream, {
      status: 200,
      headers: { "Content-Type": "application/x-ndjson", ...CLIENT_CORS_HEADERS }
    });
  }

  var userPubkey = body.pubkey;
  if (!userPubkey || !/^[0-9a-f]{64}$/i.test(userPubkey)) return json({ error: "Invalid pubkey" }, 400);
  userPubkey = userPubkey.toLowerCase();
  if (!clientAuthOk(context, body, userPubkey)) return json({ error: "Authentication failed" }, 401);

  if (body.action === "zap-put") {
    var events = Array.isArray(body.events) ? body.events.slice(0, 100)
      : (body.event ? [body.event] : []);
    var now = Date.now();
    if (!(await storageRateTake("zap-put", userPubkey, Math.max(1, events.length), ZAP_PUT_RATE))) {
      return json({ error: "Too many zap receipts. Try again in a minute." }, 429);
    }
    var chan = [];
    var pm = [];
    var candidates = [];
    for (var n = 0; n < events.length; n++) {
      var ev = events[n];
      if (!zapIsValidReceipt(ev, now)) continue;
      if (JSON.stringify(ev).length > ZAP_EVENT_MAX) continue;
      var info = zapClassify(ev);
      if (!info) continue;
      candidates.push({ ev: ev, info: info });
    }
    var verified = candidates.length ? await zapFilterByProvider(context, candidates) : [];
    verified.forEach(function (c) {
      // Channel and profile zaps live in the channels DB; PM zaps in the PM DB.
      if (c.info.scope === "channel" || c.info.scope === "profile") chan.push({ ev: c.ev, targetId: c.info.targetId });
      else if (c.info.scope === "pm") pm.push({ ev: c.ev, targetId: c.info.targetId });
    });
    var added = 0;
    added += await zapInsert(env.DB_CHANNELS, chan, now);
    added += await zapInsert(env.DB_PM, pm, now);
    return json({ ok: true, added: added });
  }

  return json({ error: "Unknown action" }, 400);
}

// Shared by the HTTP endpoint and the /api WebSocket worker (which sets context._wsAuthedPubkey).
async function routeStorageAction(context, body) {
  var replayed = await storageReplayRefusal(context, body);
  if (replayed) return replayed;
  if (body && typeof body.action === "string" && body.action.indexOf("settings-") === 0) {
    try {
      return await handleSettingsAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("account-") === 0) {
    try {
      return await handleAccountAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("profile-") === 0) {
    try {
      return await handleProfileAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("pm-") === 0) {
    try {
      return await handlePmAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && (body.action.indexOf("channel-") === 0 || body.action === "event-get")) {
    try {
      return await handleChannelAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("emoji-") === 0) {
    try {
      return await handleEmojiAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("zap-") === 0) {
    try {
      return await handleZapAction(context, body);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  if (body && typeof body.action === "string" && body.action.indexOf("shop-") === 0) {
    const privkey = context.env.BOT_PRIVKEY;
    let pubkey = null;
    if (privkey) {
      try { pubkey = getPublicKey(privkey); } catch (e) { pubkey = null; }
    }
    try {
      return await handleShopAction(context, body, privkey, pubkey);
    } catch (e) {
      console.error("storage action error:", e);
      return new Response(JSON.stringify({ error: "Internal server error" }), {
        status: 500, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
      });
    }
  }

  return new Response(JSON.stringify({ error: "Unknown action" }), {
    status: 400, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
  });
}

async function onRequest(context) {
  const { request } = context;

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CLIENT_CORS_HEADERS });
  }
  if (request.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST required" }), {
      status: 405, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  }
  if (!isNymchatClient(request, context.env)) {
    return new Response(JSON.stringify({ error: "Forbidden" }), {
      status: 403, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400, headers: { "Content-Type": "application/json", ...CLIENT_CORS_HEADERS }
    });
  }

  return await routeStorageAction(context, body);
}

export {
  onRequest,
  routeStorageAction
};
