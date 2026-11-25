// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
// The pixel mascot as data (from assets/pixelbot.py), drawn as crisp SVG with a few living details.
(function () {
  const SPRITE = ["..............KKKK..............", ".............KTWTTK.............", ".............KTTTTK.............", "..............KKKK..............", "...............KK...............", "...............KK...............", "......KKKKKKKKKKKKKKKKKKKK......", ".....KHHHHHHHHHHHHHHHHHHHHK.....", ".....KOKKKKKKKKKKKKKKKKKKOK.....", ".....KOKSSTTTSSSSSSSSSSSKDK.....", ".....KOKSTSSSTSSSSSSSSSSKDK.....", ".....KOKSTSWSTSSSTTTTSSSKDK.....", ".....KOKSTSSSTSSSSSSSSSSKDK.....", ".....KOKSSTTTSTSSSSSSSSSKDK.....", ".....KOKSSSSSSSTSSSSSTTSKDK.....", ".....KOKKKKKKKKKKKKKKKKKKDK.....", ".....KOOOOOOOOOOOOOOOOODDDK.....", "......KKKKKKKKKKKKKKKKKKKK......", "..............KDDK..............", ".........KKKKKKKKKKKKKK.........", "......KKKKHHHHHHHHHHHHKKKK......", "......KOOKOKKKKKKKKKKOKOOK......", "......KOOKOKTTTSSSSSKOKOOK......", "......KKKKOKTTTTTTTTKOKKKK......", ".........KOKTTTTTTTTKDK.........", ".........KOKKKKKKKKKKDK.........", ".........KKKKKKKKKKKKKK.........", ".....KKKKKKKKKKKKKKKKKKKKKK.....", "....KLGLGLGLGLGLGLGLGLGLGLGK....", "....KGAAGGAAGGAAGGAAGGAAGGGK....", "....KLGLGLGLGLGLGLGLGLGLGLGK....", ".....KKKKKKKKKKKKKKKKKKKKKK....."];
  const PAL = {"K": "#1A1430", "O": "#FF8A3D", "D": "#C85A26", "H": "#FFC291", "S": "#0B1424", "T": "#3CF2D0", "W": "#FFFFFF", "G": "#3A3452", "L": "#5C5578", "A": "#9A93BC"};
  // face screen: rows 9-14, the lens eye at cols 9-13 and the wink at cols 18-21
  function robot(opts = {}) {
    const px = opts.px || 10, wink = opts.wink || 0, glow = opts.glow ?? 1, scan = opts.scan ?? -1, beacon = opts.beacon ?? 1;
    let r = "";
    for (let y = 0; y < 32; y++) {
      const row = SPRITE[y]; let x = 0;
      while (x < 32) {
        let c = row[x];
        if (c === ".") { x++; continue; }
        // beacon pulse on the antenna tip
        let col = PAL[c];
        if (y <= 2 && c === "T") col = beacon > .5 ? "#3CF2D0" : "#1E8C7A";
        // wink: the right eye line squeezes when wink > 0
        if (wink > 0 && y === 11 && c === "T" && x >= 18 && x <= 21) col = PAL.S;
        if (wink > 0 && y === 12 && x >= 18 && x <= 21 && c === "S") col = PAL.T;
        let run = 1;
        while (x + run < 32 && SPRITE[y][x + run] === c && !(y <= 2) && !(wink > 0 && (y === 11 || y === 12))) run++;
        r += `<rect x="${x * px}" y="${y * px}" width="${run * px + .4}" height="${px + .4}" fill="${col}"/>`;
        x += run;
      }
    }
    // scanline sweeping across the face screen
    if (scan >= 0) r += `<rect x="${8 * px}" y="${(9 + scan * 6) * px}" width="${16 * px}" height="${px * .5}" fill="#3CF2D0" opacity=".18"/>`;
    const g = glow > 0 ? `<ellipse cx="${16 * px}" cy="${12 * px}" rx="${12 * px}" ry="${7 * px}" fill="#3CF2D0" opacity="${.10 * glow}" filter="url(#rvblur)"/>` : "";
    return `<svg viewBox="0 0 ${32 * px} ${32 * px}" width="${opts.size || 32 * px}" height="${opts.size || 32 * px}" shape-rendering="crispEdges" style="overflow:visible"><defs><filter id="rvblur" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="${px * 2}"/></filter></defs>${g}${r}</svg>`;
  }
  window.RoverBot = { robot, SPRITE, PAL };
})();
