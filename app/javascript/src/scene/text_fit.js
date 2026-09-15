// The calibrator's twin of app/views/api/board_printables/scene/_fit_script:
// the largest font size from maxPx down to minPx at which the words fit their
// box, by bisection to half a pixel. The render's copy is inline (the Grover
// page has no bundle), so change both together or the preview will shrink text
// differently from the render.

export function fits(box, inner) {
  return inner.scrollWidth <= box.clientWidth + 0.5 && inner.offsetHeight <= box.clientHeight + 0.5
}

// => the size applied, in px. Marks the box data-overflow when even minPx
// doesn't fit.
export function fitText(box, inner, maxPx, minPx) {
  if (!(maxPx > 0) || !(minPx > 0)) return null

  box.removeAttribute("data-overflow")
  inner.style.fontSize = `${maxPx}px`
  if (fits(box, inner)) return maxPx

  let lo = Math.min(minPx, maxPx)
  let hi = maxPx
  let best = lo
  while (hi - lo > 0.5) {
    const mid = (lo + hi) / 2
    inner.style.fontSize = `${mid}px`
    if (fits(box, inner)) {
      best = mid
      lo = mid
    } else {
      hi = mid
    }
  }
  inner.style.fontSize = `${best}px`
  if (!fits(box, inner)) box.setAttribute("data-overflow", "true")
  return best
}
