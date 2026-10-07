// OneMap basemap for Leaflet - shared by every map in the app, so they all behave the same.
// OneMap tiles (c) Singapore Land Authority - https://www.onemap.gov.sg (attribution required)
import L from 'leaflet'

export const ONEMAP_MIN_ZOOM = 11 // OneMap only covers Singapore
export const ONEMAP_NATIVE_MAX_ZOOM = 19 // most detailed tiles OneMap has
export const MAP_MAX_ZOOM = 20 // allow one extra step: Leaflet enlarges the zoom-19 tiles

export function createOneMapLayer() {
  return L.tileLayer('https://www.onemap.gov.sg/maps/tiles/Default/{z}/{x}/{y}.png', {
    minZoom: ONEMAP_MIN_ZOOM,
    maxZoom: MAP_MAX_ZOOM,
    // Past zoom 19 there are no OneMap tiles: re-use the zoom-19 ones (enlarged) instead of a blank map.
    // (We don't use detectRetina: on sharp screens it lowers the layer's max zoom by one,
    // which made the last zoom step go blank.)
    maxNativeZoom: ONEMAP_NATIVE_MAX_ZOOM,
    attribution:
      '<img src="https://www.onemap.gov.sg/web-assets/images/logo/om_logo.png" style="height:20px;width:20px;"/>&nbsp;' +
      '<a href="https://www.onemap.gov.sg/" target="_blank" rel="noopener noreferrer">OneMap</a>&nbsp;&copy;&nbsp;contributors&nbsp;&#124;&nbsp;' +
      '<a href="https://www.sla.gov.sg/" target="_blank" rel="noopener noreferrer">Singapore Land Authority</a>',
  })
}

// Creates a Leaflet map centred on Singapore with the OneMap basemap
export function createSingaporeMap(element) {
  const map = L.map(element, { minZoom: ONEMAP_MIN_ZOOM, maxZoom: MAP_MAX_ZOOM }).setView([1.3521, 103.8198], 12)
  createOneMapLayer().addTo(map)
  return map
}
