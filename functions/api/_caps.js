const MILLI_PER_CREDIT = 1000;

function figure(milli) {
  return Math.round(Math.max(0, Number(milli) || 0)) / MILLI_PER_CREDIT;
}

export function capMaxCost(body) {
  const v = body ? Number(body.maxCost) : NaN;
  return Number.isFinite(v) && v > 0 ? Math.round(v * MILLI_PER_CREDIT) / MILLI_PER_CREDIT : null;
}

export function capMilli(maxCost) {
  return maxCost == null ? null : Math.floor(maxCost * MILLI_PER_CREDIT);
}

export function capRefusal(requiredMilli, maxCost, pro) {
  if (maxCost == null) return null;
  const need = Math.ceil(Number(requiredMilli) || 0);
  if (need <= capMilli(maxCost)) return null;
  const required = figure(need);
  const unit = pro ? " Pro credits" : " credits";
  return {
    capExceeded: true,
    pro: !!pro,
    required: required,
    maxCost: maxCost,
    error: "This reply could cost up to " + required + unit + ", more than the " + maxCost + unit
      + " this chat allows for one reply. Nothing was sent to a model and nothing was charged."
  };
}

export function capClampCharge(cost, costMilli, maxCost) {
  const limit = capMilli(maxCost);
  if (limit == null) return { cost: cost, costMilli: costMilli, clamped: false };
  if (costMilli > 0) {
    return costMilli > limit
      ? { cost: 0, costMilli: limit, clamped: true }
      : { cost: cost, costMilli: costMilli, clamped: false };
  }
  if (cost * MILLI_PER_CREDIT > limit) return { cost: 0, costMilli: limit, clamped: true };
  return { cost: cost, costMilli: costMilli, clamped: false };
}

export function capGuard(limitMilli, priceOf, firstCallMilli, reason) {
  let before = 0;
  let extra = 0;
  let last = Math.max(0, Number(firstCallMilli) || 0);
  const spentOf = function (usage) {
    const v = Number(priceOf(usage));
    return Number.isFinite(v) && v > 0 ? v : 0;
  };
  const seen = function (usage) {
    const spent = spentOf(usage);
    if (spent > before) {
      last = spent - before;
      before = spent;
    }
    return spent;
  };
  return {
    limit: limitMilli,
    reason: reason === "balance" ? "balance" : "cap",
    room: function (usage, calls) {
      const spent = seen(usage);
      const n = Math.max(1, Math.floor(Number(calls) || 1));
      return spent + extra + n * last <= limitMilli;
    },
    left: function (usage) {
      return Math.max(0, limitMilli - seen(usage) - extra - last);
    },
    spend: function (milli) {
      const v = Number(milli);
      if (Number.isFinite(v) && v > 0) extra += v;
    },
    spent: function () {
      return extra;
    }
  };
}

export function capStoppedReply(sofar, reason) {
  const note = reason === "balance"
    ? "I stopped here because the next step could have cost more than your balance had room for. Everything so far is saved, so carrying on picks up from exactly this point, and you were only charged for the steps that ran."
    : "I stopped here to stay inside the spending cap this chat sets for one reply: the next step could have gone past it. Everything so far is saved, so carrying on picks up from exactly this point, and you were only charged for the steps that ran.";
  const text = String(sofar || "").trim();
  return text ? text + "\n\n_" + note + "_" : note;
}
