'use strict';

class RouteFailure extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
const fail = (code, message) => { throw new RouteFailure(code, message); };
function requireAppCheck(request) {
  if (typeof request?.app?.appId !== 'string' || !request.app.appId) fail('unauthenticated', '請使用已驗證的 App。');
}
function validateRequest(data) {
  if (!data || data.schemaVersion !== 1 || typeof data.requestId !== 'string' || !/^[\w-]{1,100}$/.test(data.requestId)) fail('invalid-argument', '路線請求格式無效。');
  const p = data.origin;
  if (!p || !Number.isFinite(p.latitude) || !Number.isFinite(p.longitude) || Math.abs(p.latitude) > 90 || Math.abs(p.longitude) > 180) fail('invalid-argument', '起點座標無效。');
  if (typeof data.destinationPlaceId !== 'string' || !/^[\w-]{1,256}$/.test(data.destinationPlaceId)) fail('invalid-argument', '目的地識別碼無效。');
  return {schemaVersion: 1, requestId: data.requestId, origin: {latitude: p.latitude, longitude: p.longitude}, destinationPlaceId: data.destinationPlaceId};
}
function decodePolyline(encoded) {
  if (typeof encoded !== 'string' || encoded.length > 200000) fail('unavailable', '路線資料無效。');
  const points = []; let offset = 0, lat = 0, lng = 0;
  const integer = () => {
    let value = 0, shift = 0, byte;
    do {
      if (offset >= encoded.length || shift > 30) fail('unavailable', '路線資料無效。');
      byte = encoded.charCodeAt(offset++) - 63;
      if (byte < 0 || byte > 63) fail('unavailable', '路線資料無效。');
      value |= (byte & 31) << shift; shift += 5;
    } while (byte >= 32);
    return value & 1 ? ~(value >>> 1) : value >>> 1;
  };
  while (offset < encoded.length) {
    lat += integer(); lng += integer();
    const p = {latitude: lat / 1e5, longitude: lng / 1e5};
    if (Math.abs(p.latitude) > 90 || Math.abs(p.longitude) > 180 || points.length >= 20000) fail('unavailable', '路線資料無效。');
    points.push(p);
  }
  return points;
}
function normalizeRoute(payload, requestId) {
  const route = payload?.routes?.[0];
  if (!route) fail('not-found', '未找到可用的步行路線。');
  const duration = /^([0-9]+(?:\.[0-9]+)?)s$/.exec(route.duration || '');
  if (!Number.isFinite(route.distanceMeters) || route.distanceMeters <= 0 || !duration) fail('unavailable', '路線資料無效。');
  const polyline = decodePolyline(route.polyline?.encodedPolyline);
  const steps = (route.legs || []).flatMap(leg => (leg.steps || []).map(step => ({
    instructions: String(step.navigationInstruction?.instructions || '').replace(/<[^>]*>/g, ''),
    maneuver: step.navigationInstruction?.maneuver || 'unknown', notice: '',
    polyline: decodePolyline(step.polyline?.encodedPolyline),
  })));
  if (polyline.length < 2 || !steps.length) fail('not-found', '未取得完整的步行路線。');
  return {provider: 'google', id: requestId, polyline, steps, distance: route.distanceMeters, duration: Number(duration[1]), notices: ['Google Maps 步行路線仍屬測試功能，可能缺少行人路或步行通道資料。', ...(route.warnings || []).filter(w => typeof w === 'string')]};
}
async function computeWalkingRoute(data, {key, fetcher = fetch} = {}) {
  const request = validateRequest(data);
  if (!key) fail('failed-precondition', '路線服務尚未配置。');
  let response;
  try {
    response = await fetcher('https://routes.googleapis.com/directions/v2:computeRoutes', {
      method: 'POST', signal: AbortSignal.timeout(12000),
      headers: {'Content-Type': 'application/json', 'X-Goog-Api-Key': key, 'X-Goog-FieldMask': 'routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.legs.steps.polyline.encodedPolyline,routes.legs.steps.navigationInstruction,routes.warnings'},
      body: JSON.stringify({origin: {location: {latLng: request.origin}}, destination: {placeId: request.destinationPlaceId}, travelMode: 'WALK', languageCode: 'zh-TW', regionCode: 'HK', units: 'METRIC', computeAlternativeRoutes: false}),
    });
  } catch (_) { fail('deadline-exceeded', '路線服務未有回應，請稍後重試。'); }
  if (response.status === 429) fail('resource-exhausted', '路線查詢配額暫時用盡。');
  if (!response.ok) fail('unavailable', '路線服務暫時不可用。');
  try { return normalizeRoute(await response.json(), request.requestId); }
  catch (e) { if (e instanceof RouteFailure) throw e; fail('unavailable', '路線資料無效。'); }
}
module.exports = {RouteFailure, requireAppCheck, validateRequest, decodePolyline, normalizeRoute, computeWalkingRoute};
