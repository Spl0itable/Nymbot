import { ApiRouter } from "./_apirouter.js";
import { registerModels } from "./_apimodels.js";
import { registerKeys } from "./_apikeys.js";
import { registerAccount } from "./_apibill.js";
import { registerChat } from "./_apichat.js";
import { registerResponses } from "./_apiresponses.js";
import { registerMessages } from "./_apimessages.js";
import { registerTopup } from "./_apitopup.js";
import { registerMedia } from "./_apimedia.js";
import { registerAudio } from "./_apiaudio.js";
import { registerEmbeddings } from "./_apiembed.js";
import { registerL402 } from "./_apil402.js";

export const API_REGISTRARS = [registerModels, registerKeys, registerAccount, registerChat, registerResponses, registerMessages, registerTopup, registerMedia, registerAudio, registerEmbeddings, registerL402];

let router = null;

export function apiRouter() {
  if (!router) {
    router = new ApiRouter();
    for (const register of API_REGISTRARS) register(router);
  }
  return router;
}

export async function apiV1(context) {
  return apiRouter().handle(context);
}
