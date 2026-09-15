// 4-point perspective solve, for the scene calibrator's live preview.
//
// Port of speakanyway-printables' src/templates/shared/homography.ts, and the
// JS twin of Boards::Printables::Homography + SceneSlot. The preview has to
// warp exactly the way the Grover render will, so this is fixed maths: a
// divergence from the Ruby is a bug, not a decision.
//
// A quad is [[x, y], [x, y], [x, y], [x, y]], clockwise from top-left.

export const solveHomography = (srcW, srcH, quad) => {
  if (!(srcW > 0) || !(srcH > 0)) {
    throw new Error(`solveHomography: invalid src size ${srcW}x${srcH}`)
  }
  const src = [[0, 0], [srcW, 0], [srcW, srcH], [0, srcH]]

  const m = []
  for (let i = 0; i < 4; i += 1) {
    const [x, y] = src[i]
    const [X, Y] = quad[i]
    m.push([x, y, 1, 0, 0, 0, -x * X, -y * X, X])
    m.push([0, 0, 0, x, y, 1, -x * Y, -y * Y, Y])
  }

  for (let col = 0; col < 8; col += 1) {
    let pivot = col
    for (let row = col + 1; row < 8; row += 1) {
      if (Math.abs(m[row][col]) > Math.abs(m[pivot][col])) pivot = row
    }
    if (Math.abs(m[pivot][col]) < 1e-12) {
      throw new Error("solveHomography: degenerate quad (collinear or coincident corners)")
    }
    if (pivot !== col) {
      const tmp = m[col]
      m[col] = m[pivot]
      m[pivot] = tmp
    }
    for (let row = 0; row < 8; row += 1) {
      if (row === col) continue
      const factor = m[row][col] / m[col][col]
      if (factor === 0) continue
      for (let k = col; k < 9; k += 1) m[row][k] -= factor * m[col][k]
    }
  }

  return m.map((row, i) => row[8] / row[i])
}

// CSS matrix3d for an element of srcW x srcH with transform-origin 0 0.
// Column-major, the projective 3x3 embedded with the z row/column as identity.
export const quadToMatrix3d = (srcW, srcH, quad) => {
  const [a, b, c, d, e, f, g, h] = solveHomography(srcW, srcH, quad)
  const cells = [a, d, 0, g, b, e, 0, h, 0, 0, 1, 0, c, f, 0, 1]
  return `matrix3d(${cells.map((n) => Number(n.toPrecision(8))).join(", ")})`
}

const distance = (a, b) => Math.hypot(b[0] - a[0], b[1] - a[1])

// SceneSlot#target_width / #target_height: the quad's own proportions.
export const targetSize = (quad) => {
  const [tl, tr, br, bl] = quad
  return {
    width: Math.round((distance(tl, tr) + distance(bl, br)) / 2),
    height: Math.round((distance(tl, bl) + distance(tr, br)) / 2),
  }
}

// SceneSlot#clockwise_convex?
export const isClockwiseConvex = (quad) => {
  for (let i = 0; i < 4; i += 1) {
    const a = quad[i]
    const b = quad[(i + 1) % 4]
    const c = quad[(i + 2) % 4]
    const cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
    if (!(cross > 0)) return false
  }
  return true
}
