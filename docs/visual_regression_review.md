# 🔬 Hub de Revue des Références Visuelles (Golden References)

**Date** : 10 Septembre 2026  
**Outil de Visualisation** : Serveur local MkDocs Material avec canvas interactif à zoom/pan synchronisé (`task serve-docs` sur `http://localhost:8080`)  
**Statut** : 🟡 En attente de validation humaine (Phase 1 — PBR & IBL)  

---

## 🎯 1. Rôle & Fonctionnement du Hub de Revue

Le moteur `suckless-odin` intègre un banc de tests de régression visuelle automatisé ([`tests/gl/test_visual_regression.odin`](file:///home/latty/Prog/__PERSO__/suckless-odin/tests/gl/test_visual_regression.odin)) qui capture la scène complète (sphères PBR, éclairage IBL, ciel HDR) depuis 6 points de vue cardinaux (`front`, `back`, `left`, `right`, `top`, `bottom`).

Chaque pixel est comparé à l'image dorée de référence correspondante dans `tests/references/ref_*.png`. Conformément à la politique absolue `AGENTS.md`, **aucune mise à jour de ces images de référence ne peut être effectuée automatiquement sans validation explicite**.

Ce visualiseur sur canvas HTML5 élimine les conflits de lightbox et garantit un **zoom, déplacement et réticule spatial 100% synchronisés** au pixel près.

---

## 🔍 2. Visualiseur Canvas Synchrone (Pan & Zoom Multi-Vues)

> [!TIP]
> **Commandes directes sur les canvas** :
> * **Molette souris** : Zoom / Dézoom synchrone centré sur la position de votre curseur (de $1\times$ à $16\times$).
> * **Clic gauche + Glisser** : Déplacement panoramique (Pan) instantané et simultané sur toutes les vues.
> * **Survol souris** : Réticule rouge synchronisé et sonde colorimétrique RGB en temps réel sous le pointeur.
> * **Touches clavier** : `+` / `-` pour zoomer, `0` ou `R` pour réinitialiser le cadrage.

<div class="sync-canvas-app" id="sync-canvas-app">
  <!-- Barre d'outils -->
  <div class="sync-toolbar">
    <div class="sync-toolbar-group">
      <label for="vp-select">Point de Vue :</label>
      <select id="vp-select" class="sync-select">
        <option value="front" selected>Front (Vue Face)</option>
        <option value="back">Back (Vue Arrière)</option>
        <option value="left">Left (Vue Gauche)</option>
        <option value="right">Right (Vue Droite)</option>
        <option value="top">Top (Vue Haut)</option>
        <option value="bottom">Bottom (Vue Bas)</option>
      </select>
    </div>

    <div class="sync-toolbar-group">
      <label>Mode :</label>
      <div class="sync-btn-group">
        <button type="button" class="sync-btn active" id="mode-2pane">2 Vues (Ref / Actuel)</button>
        <button type="button" class="sync-btn" id="mode-3pane">3 Vues (+ Diff Mask)</button>
        <button type="button" class="sync-btn" id="mode-split">Slider A/B Superposé</button>
      </div>
    </div>

    <div class="sync-toolbar-group">
      <div class="sync-btn-group">
        <button type="button" class="sync-btn" id="btn-zoom-in" title="Zoomer (+)">➕</button>
        <button type="button" class="sync-btn" id="btn-zoom-out" title="Dézoomer (-)">➖</button>
        <button type="button" class="sync-btn" id="btn-zoom-1x" title="Zoom 100%">1:1</button>
        <button type="button" class="sync-btn" id="btn-zoom-4x" title="Zoom 400%">4x</button>
        <button type="button" class="sync-btn" id="btn-reset" title="Réinitialiser vue">🔄 Reset</button>
      </div>
      <span class="sync-badge" id="zoom-badge">Zoom: 1.0x</span>
    </div>
  </div>

  <!-- Zone d'affichage : Canvases Synchronisés -->
  <div class="sync-canvases-container" id="canvases-side-by-side">
    <div class="sync-canvas-card" id="card-ref">
      <div class="sync-canvas-header header-ref">
        <span>🟧 RÉFÉRENCE DORÉE (Bug: LOD=4.0)</span>
      </div>
      <div class="sync-canvas-wrapper">
        <canvas id="canvas-ref" width="512" height="384"></canvas>
      </div>
    </div>

    <div class="sync-canvas-card" id="card-actual">
      <div class="sync-canvas-header header-actual">
        <span>🟩 RENDU ACTUEL (Fix: LOD=10.0)</span>
      </div>
      <div class="sync-canvas-wrapper">
        <canvas id="canvas-actual" width="512" height="384"></canvas>
      </div>
    </div>

    <div class="sync-canvas-card" id="card-diff" style="display: none;">
      <div class="sync-canvas-header header-diff">
        <span>🟥 MASQUE D'ÉCARTS (&gt; 5 RGB)</span>
      </div>
      <div class="sync-canvas-wrapper">
        <canvas id="canvas-diff" width="512" height="384"></canvas>
      </div>
    </div>
  </div>

  <!-- Zone d'affichage : Slider A/B Superposé -->
  <div class="sync-split-container" id="canvases-split-wrapper" style="display: none;">
    <div class="sync-canvas-header header-split">
      <span>↔️ SLIDER A/B SUPERPOSÉ (Déplacez la barre centrale pour comparer)</span>
    </div>
    <div class="sync-canvas-wrapper">
      <canvas id="canvas-split" width="1024" height="768"></canvas>
    </div>
  </div>

  <!-- Barre de télémétrie et d'inspection au pixel près -->
  <div class="sync-telemetry-bar">
    <div class="sync-telemetry-item" id="probe-coords">Pixel : (X: --, Y: --)</div>
    <div class="sync-telemetry-item" id="probe-ref">Ref RGB : --</div>
    <div class="sync-telemetry-item" id="probe-actual">Actuel RGB : --</div>
    <div class="sync-telemetry-item" id="probe-diff">Delta : --</div>
  </div>
</div>

<style>
.sync-canvas-app {
  background: #14161d;
  border: 1px solid #2e3240;
  border-radius: 8px;
  overflow: hidden;
  margin: 1.5rem 0 2rem 0;
  color: #e2e4ee;
  box-shadow: 0 10px 30px rgba(0,0,0,0.5);
  user-select: none;
}

.sync-toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  padding: 0.65rem 1rem;
  background: #1c1e28;
  border-bottom: 1px solid #2e3240;
  gap: 0.75rem;
}

.sync-toolbar-group {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  font-size: 0.85rem;
}

.sync-select {
  background: #0f1015;
  color: #ffffff;
  border: 1px solid #44485c;
  border-radius: 4px;
  padding: 0.35rem 0.65rem;
  font-size: 0.85rem;
  cursor: pointer;
  outline: none;
}

.sync-btn-group {
  display: inline-flex;
  border-radius: 4px;
  overflow: hidden;
  border: 1px solid #44485c;
}

.sync-btn {
  background: #252836;
  color: #cfd2df;
  border: none;
  padding: 0.4rem 0.75rem;
  font-size: 0.82rem;
  cursor: pointer;
  transition: all 0.15s;
  outline: none;
}

.sync-btn:hover {
  background: #363b4e;
  color: #fff;
}

.sync-btn.active {
  background: #0097a7;
  color: #fff;
  font-weight: bold;
}

.sync-badge {
  background: #0d0f14;
  border: 1px solid #44485c;
  border-radius: 4px;
  padding: 0.35rem 0.65rem;
  font-size: 0.82rem;
  font-family: monospace;
  color: #00e5ff;
}

.sync-canvases-container {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 2px;
  background: #2e3240;
}

.sync-canvases-container.mode-3pane {
  grid-template-columns: 1fr 1fr 1fr;
}

.sync-canvas-card {
  display: flex;
  flex-direction: column;
  background: #0a0b0e;
  overflow: hidden;
}

.sync-canvas-header {
  padding: 0.45rem 0.8rem;
  font-size: 0.75rem;
  font-weight: 700;
  letter-spacing: 0.5px;
}

.header-ref {
  background: rgba(255, 152, 0, 0.18);
  color: #ffb74d;
  border-bottom: 2px solid #ff9800;
}

.header-actual {
  background: rgba(76, 175, 80, 0.18);
  color: #81c784;
  border-bottom: 2px solid #4caf50;
}

.header-diff {
  background: rgba(244, 67, 54, 0.18);
  color: #e57373;
  border-bottom: 2px solid #f44336;
}

.header-split {
  background: rgba(0, 188, 212, 0.18);
  color: #4dd0e1;
  border-bottom: 2px solid #00bcd4;
}

.sync-canvas-wrapper {
  position: relative;
  width: 100%;
  aspect-ratio: 4 / 3;
  background: #060709;
  cursor: crosshair;
  overflow: hidden;
}

.sync-canvas-wrapper canvas {
  width: 100%;
  height: 100%;
  display: block;
}

.sync-split-container {
  display: flex;
  flex-direction: column;
  background: #0a0b0e;
}

.sync-telemetry-bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  padding: 0.5rem 1rem;
  background: #181a23;
  border-top: 1px solid #2e3240;
  font-family: monospace;
  font-size: 0.78rem;
  color: #9da1b5;
}

.sync-telemetry-item {
  display: inline-block;
  padding: 0.15rem 0.4rem;
  border-radius: 3px;
  background: #0f1015;
}

@media (max-width: 850px) {
  .sync-canvases-container, .sync-canvases-container.mode-3pane {
    grid-template-columns: 1fr;
  }
}
</style>

<script>
(function() {
  const IMG_W = 512;
  const IMG_H = 384;

  let vp = 'front';
  let mode = '2pane'; // '2pane', '3pane', 'split'

  let scale = 1.0;
  let panX = 0;
  let panY = 0;
  let isPanning = false;
  let startMouseX = 0;
  let startMouseY = 0;
  let startPanX = 0;
  let startPanY = 0;

  let splitRatio = 0.5;
  let isSplitDragging = false;

  let cursorImgX = -1;
  let cursorImgY = -1;

  // Images
  const imgRef = new Image();
  const imgActual = new Image();
  const imgDiff = new Image();

  // Canvases
  const cRef = document.getElementById('canvas-ref');
  const cActual = document.getElementById('canvas-actual');
  const cDiff = document.getElementById('canvas-diff');
  const cSplit = document.getElementById('canvas-split');

  const ctxRef = cRef.getContext('2d', { willReadFrequently: true });
  const ctxActual = cActual.getContext('2d', { willReadFrequently: true });
  const ctxDiff = cDiff.getContext('2d', { willReadFrequently: true });
  const ctxSplit = cSplit.getContext('2d');

  // Offscreen analysis buffers for exact pixel probing
  const offCanvasRef = document.createElement('canvas');
  offCanvasRef.width = IMG_W;
  offCanvasRef.height = IMG_H;
  const offCtxRef = offCanvasRef.getContext('2d', { willReadFrequently: true });

  const offCanvasActual = document.createElement('canvas');
  offCanvasActual.width = IMG_W;
  offCanvasActual.height = IMG_H;
  const offCtxActual = offCanvasActual.getContext('2d', { willReadFrequently: true });

  // DOM elements
  const vpSelect = document.getElementById('vp-select');
  const mode2Pane = document.getElementById('mode-2pane');
  const mode3Pane = document.getElementById('mode-3pane');
  const modeSplit = document.getElementById('mode-split');
  const zoomBadge = document.getElementById('zoom-badge');
  const probeCoords = document.getElementById('probe-coords');
  const probeRef = document.getElementById('probe-ref');
  const probeActual = document.getElementById('probe-actual');
  const probeDiff = document.getElementById('probe-diff');

  const sideBySideBox = document.getElementById('canvases-side-by-side');
  const splitBox = document.getElementById('canvases-split-wrapper');
  const cardDiff = document.getElementById('card-diff');

  function getBaseUrl() {
    const isSubdir = window.location.pathname.endsWith('/') && window.location.pathname !== '/';
    return isSubdir ? '../' : '';
  }

  function loadViewpoint(name) {
    vp = name;
    const base = getBaseUrl();
    imgRef.crossOrigin = 'anonymous';
    imgActual.crossOrigin = 'anonymous';
    imgDiff.crossOrigin = 'anonymous';

    let loaded = 0;
    function onImageLoad() {
      loaded++;
      if (loaded === 3) {
        offCtxRef.drawImage(imgRef, 0, 0);
        offCtxActual.drawImage(imgActual, 0, 0);
        renderAll();
      }
    }

    imgRef.onload = onImageLoad;
    imgActual.onload = onImageLoad;
    imgDiff.onload = onImageLoad;

    imgRef.src = base + 'images/references/ref_' + vp + '.png';
    imgActual.src = base + 'images/references/actual_' + vp + '.png';
    imgDiff.src = base + 'images/references/diff_' + vp + '.png';
  }

  function renderPane(ctx, img) {
    const cw = ctx.canvas.width;
    const ch = ctx.canvas.height;
    ctx.clearRect(0, 0, cw, ch);

    ctx.imageSmoothingEnabled = scale < 2.0;

    const dw = cw * scale;
    const dh = ch * scale;
    const dx = panX;
    const dy = panY;

    if (img.complete && img.naturalWidth > 0) {
      ctx.drawImage(img, dx, dy, dw, dh);
    }

    // Draw Crosshair
    if (cursorImgX >= 0 && cursorImgY >= 0) {
      const cx = (cursorImgX / IMG_W) * dw + dx;
      const cy = (cursorImgY / IMG_H) * dh + dy;

      ctx.save();
      ctx.strokeStyle = '#ff3d00';
      ctx.lineWidth = 1.5;
      ctx.shadowColor = '#000000';
      ctx.shadowBlur = 4;

      ctx.beginPath();
      ctx.arc(cx, cy, 6, 0, Math.PI * 2);
      ctx.stroke();

      ctx.beginPath();
      ctx.moveTo(cx - 10, cy);
      ctx.lineTo(cx + 10, cy);
      ctx.moveTo(cx, cy - 10);
      ctx.lineTo(cx, cy + 10);
      ctx.stroke();
      ctx.restore();
    }
  }

  function renderSplit() {
    const cw = cSplit.width;
    const ch = cSplit.height;
    ctxSplit.clearRect(0, 0, cw, ch);

    ctxSplit.imageSmoothingEnabled = scale < 2.0;
    const dw = cw * scale;
    const dh = ch * scale;
    const dx = panX * (cw / IMG_W);
    const dy = panY * (ch / IMG_H);

    // 1. Draw Reference (Base)
    if (imgRef.complete) {
      ctxSplit.drawImage(imgRef, dx, dy, dw, dh);
    }

    // 2. Draw Actual with Clip
    const splitX = cw * splitRatio;
    ctxSplit.save();
    ctxSplit.beginPath();
    ctxSplit.rect(splitX, 0, cw - splitX, ch);
    ctxSplit.clip();
    if (imgActual.complete) {
      ctxSplit.drawImage(imgActual, dx, dy, dw, dh);
    }
    ctxSplit.restore();

    // 3. Draw Divider Line
    ctxSplit.save();
    ctxSplit.strokeStyle = '#00e5ff';
    ctxSplit.lineWidth = 3;
    ctxSplit.shadowColor = '#000';
    ctxSplit.shadowBlur = 6;
    ctxSplit.beginPath();
    ctxSplit.moveTo(splitX, 0);
    ctxSplit.lineTo(splitX, ch);
    ctxSplit.stroke();

    // Divider handle
    ctxSplit.fillStyle = '#00bcd4';
    ctxSplit.beginPath();
    ctxSplit.arc(splitX, ch / 2, 14, 0, Math.PI * 2);
    ctxSplit.fill();
    ctxSplit.stroke();
    ctxSplit.restore();
  }

  function renderAll() {
    if (mode === 'split') {
      renderSplit();
    } else {
      renderPane(ctxRef, imgRef);
      renderPane(ctxActual, imgActual);
      if (mode === '3pane') {
        renderPane(ctxDiff, imgDiff);
      }
    }
    zoomBadge.textContent = 'Zoom: ' + scale.toFixed(1) + 'x';
  }

  function zoomAt(targetScale, clientX, clientY, canvasElem) {
    const rect = canvasElem.getBoundingClientRect();
    const mouseCanvasX = (clientX - rect.left) * (canvasElem.width / rect.width);
    const mouseCanvasY = (clientY - rect.top) * (canvasElem.height / rect.height);

    const oldScale = scale;
    scale = Math.max(1.0, Math.min(16.0, targetScale));

    panX = mouseCanvasX - (mouseCanvasX - panX) * (scale / oldScale);
    panY = mouseCanvasY - (mouseCanvasY - panY) * (scale / oldScale);

    if (scale <= 1.0) {
      scale = 1.0;
      panX = 0;
      panY = 0;
    }
    renderAll();
  }

  function updateProbe(imgX, imgY) {
    cursorImgX = Math.floor(imgX);
    cursorImgY = Math.floor(imgY);

    if (cursorImgX < 0 || cursorImgX >= IMG_W || cursorImgY < 0 || cursorImgY >= IMG_H) {
      probeCoords.textContent = 'Pixel : (Hors Cadre)';
      probeRef.textContent = 'Ref RGB : --';
      probeActual.textContent = 'Actuel RGB : --';
      probeDiff.textContent = 'Delta : --';
      return;
    }

    probeCoords.textContent = `Pixel : (X: ${cursorImgX}, Y: ${cursorImgY})`;

    try {
      const pRef = offCtxRef.getImageData(cursorImgX, cursorImgY, 1, 1).data;
      const pAct = offCtxActual.getImageData(cursorImgX, cursorImgY, 1, 1).data;

      probeRef.innerHTML = `Ref RGB : <span style="color:rgb(${pRef[0]},${pRef[1]},${pRef[2]})">■</span> (${pRef[0]}, ${pRef[1]}, ${pRef[2]})`;
      probeActual.innerHTML = `Actuel RGB : <span style="color:rgb(${pAct[0]},${pAct[1]},${pAct[2]})">■</span> (${pAct[0]}, ${pAct[1]}, ${pAct[2]})`;

      const dR = Math.abs(pRef[0] - pAct[0]);
      const dG = Math.abs(pRef[1] - pAct[1]);
      const dB = Math.abs(pRef[2] - pAct[2]);
      const dist = Math.sqrt(dR*dR + dG*dG + dB*dB);

      if (dist > 5.0) {
        probeDiff.innerHTML = `<span style="color:#ff5252;font-weight:bold;">Delta : ${dist.toFixed(1)} (Différ.)</span>`;
      } else {
        probeDiff.innerHTML = `<span style="color:#69f0ae;">Delta : ${dist.toFixed(1)} (Ident.)</span>`;
      }
    } catch(e) {}
  }

  // Bind mouse / touch events to a canvas
  function bindCanvasEvents(canvas) {
    canvas.addEventListener('wheel', function(e) {
      e.preventDefault();
      const factor = e.deltaY < 0 ? 1.25 : 0.8;
      zoomAt(scale * factor, e.clientX, e.clientY, canvas);
    }, { passive: false });

    canvas.addEventListener('mousedown', function(e) {
      if (mode === 'split') {
        const rect = canvas.getBoundingClientRect();
        const mouseX = (e.clientX - rect.left) * (canvas.width / rect.width);
        const splitX = canvas.width * splitRatio;
        if (Math.abs(mouseX - splitX) < 25) {
          isSplitDragging = true;
          return;
        }
      }
      isPanning = true;
      startMouseX = e.clientX;
      startMouseY = e.clientY;
      startPanX = panX;
      startPanY = panY;
    });

    canvas.addEventListener('mousemove', function(e) {
      const rect = canvas.getBoundingClientRect();
      const canvasMouseX = (e.clientX - rect.left) * (canvas.width / rect.width);
      const canvasMouseY = (e.clientY - rect.top) * (canvas.height / rect.height);

      if (isSplitDragging) {
        splitRatio = Math.max(0.02, Math.min(0.98, canvasMouseX / canvas.width));
        renderAll();
        return;
      }

      if (isPanning) {
        const deltaX = (e.clientX - startMouseX) * (canvas.width / rect.width);
        const deltaY = (e.clientY - startMouseY) * (canvas.height / rect.height);
        panX = startPanX + deltaX;
        panY = startPanY + deltaY;
        renderAll();
      }

      // Calculate corresponding image pixel coordinates
      const curPanX = mode === 'split' ? panX * (canvas.width / IMG_W) : panX;
      const curPanY = mode === 'split' ? panY * (canvas.height / IMG_H) : panY;
      const curScale = scale;
      const imgX = (canvasMouseX - curPanX) / (curScale * (canvas.width / IMG_W));
      const imgY = (canvasMouseY - curPanY) / (curScale * (canvas.height / IMG_H));

      updateProbe(imgX, imgY);
      renderAll();
    });

    canvas.addEventListener('mouseleave', function() {
      cursorImgX = -1;
      cursorImgY = -1;
      renderAll();
    });
  }

  window.addEventListener('mouseup', function() {
    isPanning = false;
    isSplitDragging = false;
  });

  [cRef, cActual, cDiff, cSplit].forEach(bindCanvasEvents);

  // Toolbar events
  vpSelect.addEventListener('change', function() {
    loadViewpoint(this.value);
  });

  function setMode(newMode) {
    mode = newMode;
    [mode2Pane, mode3Pane, modeSplit].forEach(b => b.classList.remove('active'));

    if (mode === '2pane') {
      mode2Pane.classList.add('active');
      sideBySideBox.style.display = 'grid';
      sideBySideBox.className = 'sync-canvases-container';
      cardDiff.style.display = 'none';
      splitBox.style.display = 'none';
    } else if (mode === '3pane') {
      mode3Pane.classList.add('active');
      sideBySideBox.style.display = 'grid';
      sideBySideBox.className = 'sync-canvases-container mode-3pane';
      cardDiff.style.display = 'flex';
      splitBox.style.display = 'none';
    } else if (mode === 'split') {
      modeSplit.classList.add('active');
      sideBySideBox.style.display = 'none';
      splitBox.style.display = 'flex';
    }
    renderAll();
  }

  mode2Pane.addEventListener('click', () => setMode('2pane'));
  mode3Pane.addEventListener('click', () => setMode('3pane'));
  modeSplit.addEventListener('click', () => setMode('split'));

  document.getElementById('btn-zoom-in').addEventListener('click', function() {
    const c = (mode === 'split') ? cSplit : cActual;
    const r = c.getBoundingClientRect();
    zoomAt(scale * 1.35, r.left + r.width / 2, r.top + r.height / 2, c);
  });

  document.getElementById('btn-zoom-out').addEventListener('click', function() {
    const c = (mode === 'split') ? cSplit : cActual;
    const r = c.getBoundingClientRect();
    zoomAt(scale * 0.75, r.left + r.width / 2, r.top + r.height / 2, c);
  });

  document.getElementById('btn-zoom-1x').addEventListener('click', function() {
    scale = 1.0;
    panX = 0;
    panY = 0;
    renderAll();
  });

  document.getElementById('btn-zoom-4x').addEventListener('click', function() {
    const c = (mode === 'split') ? cSplit : cActual;
    const r = c.getBoundingClientRect();
    zoomAt(4.0, r.left + r.width / 2, r.top + r.height / 2, c);
  });

  document.getElementById('btn-reset').addEventListener('click', function() {
    scale = 1.0;
    panX = 0;
    panY = 0;
    splitRatio = 0.5;
    renderAll();
  });

  // Initial load
  loadViewpoint('front');
})();
</script>

---

## 📊 3. Bilan Métrique Actuel : Phase 1 (PBR LOD & Specular AA)

Suite à la correction de l'échantillonnage IBL ([`MAX_REFLECTION_LOD = 10.0`](file:///home/latty/Prog/__PERSO__/suckless-odin/shaders/pbr_billboard.frag#L117)) et au lissage de la variance spéculaire, les écarts suivants sont mesurés par rapport aux anciennes références capturées avec le bug :

| Point de Vue | Pixels Différents | Pourcentage Réel | Seuil Toléré | Impact Matériaux | Fichiers Dorés |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **`front`** | 8 405 / 196 608 | **4.28%** | $\le 2.00\%$ | Sphères rugueuses ($\text{roughness} > 0.4$) | [Ref](images/references/ref_front.png) · [Actual](images/references/actual_front.png) · [Diff](images/references/diff_front.png) |
| **`back`** | 8 931 / 196 608 | **4.54%** | $\le 2.00\%$ | Sphères rugueuses ($\text{roughness} > 0.4$) | [Ref](images/references/ref_back.png) · [Actual](images/references/actual_back.png) · [Diff](images/references/diff_back.png) |
| **`left`** | 4 150 / 196 608 | **2.11%** | $\le 2.00\%$ | Sphères rugueuses ($\text{roughness} > 0.4$) | [Ref](images/references/ref_left.png) · [Actual](images/references/actual_left.png) · [Diff](images/references/diff_left.png) |
| **`right`** | 5 240 / 196 608 | **2.67%** | $\le 2.00\%$ | Sphères rugueuses ($\text{roughness} > 0.4$) | [Ref](images/references/ref_right.png) · [Actual](images/references/actual_right.png) · [Diff](images/references/diff_right.png) |
| **`top`** | 4 126 / 196 608 | **2.10%** | $\le 2.00\%$ | Sphères rugueuses ($\text{roughness} > 0.4$) | [Ref](images/references/ref_top.png) · [Actual](images/references/actual_top.png) · [Diff](images/references/diff_top.png) |
| **`bottom`** | 2 726 / 196 608 | **1.39%** | $\le 2.00\%$ | Sphères rugueuses ($\text{roughness} > 0.4$) | [Ref](images/references/ref_bottom.png) · [Actual](images/references/actual_bottom.png) · [Diff](images/references/diff_bottom.png) |

> [!NOTE]
> **Cause Physique Identifiée** : 100% des pixels en divergence sont cantonnés à la grille de sphères ($X \in [92, 419], Y \in [28, 351]$). L'arrière-plan ciel HDR présente **0.00% d'écart**. Les sphères à faible rugosité ne bougent pas ; seules les sphères mates deviennent physiquement plus diffuses (mips 5 à 10 débloqués au lieu de bloquer au mip 4).

---

## 🛠️ 4. Procédure de Revue & Validation par l'Utilisateur

1. **Lancer le serveur de documentation :**
   ```bash
   task serve-docs
   ```
   Ouvrir [`http://localhost:8080/visual_regression_review/`](http://localhost:8080/visual_regression_review/) dans le navigateur pour inspecter les planches comparatives interactives sur canvas HTML5.

2. **Vérifier les critères d'acceptation :**
   - [ ] Absence totale de dégradation ou d'artéfacts sur le ciel HDR (différence nulle).
   - [ ] Disparition du specular trop net sur les matériaux rugueux de la grille.
   - [ ] Lissage continu sur les contours rasants sans coupure de specular AA.

3. **Valider et aligner la baseline :**
   Une fois le rendu validé, régénérer les images de référence dorées :
   ```bash
   GEN_REFS=1 task test-gl
   ```
   Puis valider que le test de régression passe désormais à 100% :
   ```bash
   task test-gl
   ```
