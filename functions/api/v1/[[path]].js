import { apiV1 } from "../_apiv1.js";

export async function onRequest(context) {
  return apiV1(context);
}
