export function onRequest(context) {
  return Response.redirect(new URL("/app/", context.request.url).href, 303);
}
