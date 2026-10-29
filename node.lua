gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local json = require "json"

local font = resource.load_font "font.ttf"
local logo = resource.load_image "logo.png"

-- Couleurs E.Leclerc (approximatives) et charte claire
local BLEU   = {0.00, 0.36, 0.67}
local FOND   = {0.357, 0.557, 1.00}   -- bleu clair de l'ecran
local ORANGE = {0.97, 0.58, 0.12}
local ROUGE  = {0.85, 0.10, 0.10}
local BLANC  = {1, 1, 1}
local TUILE  = 0.30                   -- opacite du blanc des tuiles et de l'anneau

-- Couleurs des icones meteo
local SOLEIL = {1.00, 0.78, 0.17}
local NUAGE  = {0.75, 0.79, 0.83}
local GOUTTE = {0.49, 0.78, 1.00}

local function texture(c, a)
  return resource.create_colored_texture(c[1], c[2], c[3], a or 1)
end

local tex_blanc   = texture(BLANC)
local tex_bleu    = texture(BLEU)
local tex_rouge   = texture(ROUGE)
local tex_soleil  = texture(SOLEIL)
local tex_nuage   = texture(NUAGE)
local tex_goutte  = texture(GOUTTE)

-- Rectangle aux quatre coins arrondis
local shader_arrondi = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float w, h, rayon;   // en pixels
  uniform float r, g, b, opacite;
  void main() {
    vec2 demi = vec2(w, h) * 0.5;
    vec2 q = abs(TexCoord * vec2(w, h) - demi) - (demi - vec2(rayon));
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rayon;
    float a = clamp(0.5 - d, 0.0, 1.0);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(r, g, b, a * opacite);
  }
]]

-- Disque lisse dessine par un shader (pas d'image necessaire).
-- "coupe" retire un second disque : sert a dessiner le croissant de lune.
local shader_disque = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float flou;
  uniform float r, g, b;
  uniform float ox, oy, rc;
  uniform float opacite;
  void main() {
    vec2 p = (TexCoord - vec2(0.5)) * 2.0;
    float a = 1.0 - smoothstep(1.0 - flou, 1.0, length(p));
    a *= smoothstep(rc - flou, rc, length(p - vec2(ox, oy)));
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(r, g, b, a * opacite);
  }
]]

local JOURS = {"Dimanche","Lundi","Mardi","Mercredi","Jeudi","Vendredi","Samedi"}
local MOIS  = {"Janvier","Février","Mars","Avril","Mai","Juin","Juillet",
               "Août","Septembre","Octobre","Novembre","Décembre"}
local METEO_PERIMEE = 2 * 3600   -- au-dela, la meteo n'est plus affichee

-- Reglages (modifiables depuis le tableau de bord info-beamer)
local trotteuse = true
local horloge_digitale = true
local messages = {}              -- {texte =, debut = "AAAA-MM-JJ" ou nil, fin = ...}

-- Date d'un reglage info-beamer ({value = "AAAA-MM-JJ", ...}) ; nil si vide
local function date_reglage(v)
  if type(v) == "table" then v = v.value end
  if type(v) == "string" and v:match("^%d%d%d%d%-%d%d%-%d%d$") then return v end
  return nil
end

util.json_watch("config.json", function(config)
  if config.trotteuse ~= nil then trotteuse = config.trotteuse end
  if config.horloge_digitale ~= nil then horloge_digitale = config.horloge_digitale end
  messages = {}
  for _, m in ipairs(type(config.messages) == "table" and config.messages or {}) do
    if type(m.texte) == "string" and m.texte:find("%S") then
      messages[#messages + 1] = {texte = m.texte, debut = date_reglage(m.debut), fin = date_reglage(m.fin)}
    end
  end
end)

-- Meteo ecrite par le service (meteo.json), absente au premier demarrage
local meteo = nil

local function lire_meteo()
  local ok, donnees = pcall(function()
    return json.decode(resource.load_file "meteo.json")
  end)
  if ok and type(donnees) == "table" then meteo = donnees end
end

node.event("content_update", function(fichier)
  if fichier == "meteo.json" then lire_meteo() end
end)
lire_meteo()

-- Heure d'été européenne automatique (France)
local function jour_semaine(y, m, d)   -- 0 = dimanche
  local t = {0,3,2,5,0,3,5,2,6,4,2,4}
  if m < 3 then y = y - 1 end
  return (y + math.floor(y/4) - math.floor(y/100) + math.floor(y/400) + t[m] + d) % 7
end

local function decalage(utc)
  local debut = 3 * 10000 + (31 - jour_semaine(utc.year, 3, 31)) * 100 + 1
  local fin   = 10 * 10000 + (31 - jour_semaine(utc.year, 10, 31)) * 100 + 1
  local now   = utc.month * 10000 + utc.day * 100 + utc.hour
  if now >= debut and now < fin then return 7200 end
  return 3600
end

-- coupe = {dx, dy, rayon} en fractions du rayon (disque retire)
local function disque(cx, cy, rayon, c, coupe, opacite)
  coupe = coupe or {0, 0, 0}
  shader_disque:use{
    flou = 1.5 / rayon,
    r = c[1], g = c[2], b = c[3],
    ox = coupe[1], oy = coupe[2], rc = coupe[3],
    opacite = opacite or 1,
  }
  tex_blanc:draw(cx - rayon, cy - rayon, cx + rayon, cy + rayon)
  shader_disque:deactivate()
end

local function cartouche(x1, y1, x2, y2, c, rayon, opacite)
  shader_arrondi:use{w = x2 - x1, h = y2 - y1, rayon = rayon,
                     r = c[1], g = c[2], b = c[3], opacite = opacite or 1}
  tex_blanc:draw(x1, y1, x2, y2)
  shader_arrondi:deactivate()
end

-- Tuile translucide de la charte claire
local function tuile(x1, y1, x2, y2)
  cartouche(x1, y1, x2, y2, BLANC, HEIGHT * 0.022, TUILE)
end

-- Rectangle tourne autour de (cx, cy) (angle en degres, 0 = vers le haut)
-- de "debut" a "fin" le long de cette direction (negatif = cote oppose)
local function trait(cx, cy, angle, debut, fin, largeur, tex)
  gl.pushMatrix()
  gl.translate(cx, cy)
  gl.rotate(angle, 0, 0, 1)
  tex:draw(-largeur / 2, -fin, largeur / 2, -debut)
  gl.popMatrix()
end

-- Barre aux bouts arrondis de (x1, y1) a (x2, y2)
local function barre(x1, y1, x2, y2, largeur, tex, c)
  local dx, dy = x2 - x1, y2 - y1
  trait(x1, y1, math.deg(math.atan2(dx, -dy)), 0, math.sqrt(dx * dx + dy * dy), largeur, tex)
  disque(x1, y1, largeur / 2, c)
  disque(x2, y2, largeur / 2, c)
end

local function centre(texte, x, y, taille, c, a)
  local w = font:width(texte, taille)
  font:write(x - w / 2, y - taille / 2, texte, taille, c[1], c[2], c[3], a or 1)
end

-- Taille reduite si le texte depasse la largeur donnee
local function ajuste(texte, taille, largeur)
  local w = font:width(texte, taille)
  if w > largeur then return taille * largeur / w end
  return taille
end

------------------------------------------------------------------------
-- Cadran (a droite)
------------------------------------------------------------------------

local function cadran(cx, cy, R)
  -- Anneau bleu clair, lunette orange, face blanche
  disque(cx, cy, R * 1.067, BLANC, nil, TUILE)
  disque(cx, cy, R, ORANGE)
  disque(cx, cy, R * 0.95, BLANC)

  -- Graduations : minutes fines, heures epaisses
  for i = 0, 59 do
    if i % 5 == 0 then
      trait(cx, cy, i * 6, R * 0.80, R * 0.91, R * 0.022, tex_bleu)
    else
      trait(cx, cy, i * 6, R * 0.87, R * 0.91, R * 0.007, tex_bleu)
    end
  end

  for h = 1, 12 do
    local a = math.rad(h * 30)
    centre(tostring(h), cx + math.sin(a) * R * 0.68, cy - math.cos(a) * R * 0.68,
           R * 0.15, BLEU)
  end
end

local function logo_cadran(cx, cy, R)
  local iw, ih = logo:size()
  local lw = R * 0.80
  local lh = lw * ih / iw
  local y  = cy - R * 0.36 - lh / 2
  logo:draw(cx - lw / 2, y, cx + lw / 2, y + lh)
end

-- Heure digitale : pastille orange (comme la lunette) sous le centre du cadran
local function heure_digitale(cx, cy, R, d)
  local w, h = R * 0.55, R * 0.20
  local y = cy + R * 0.32
  cartouche(cx - w / 2, y - h / 2, cx + w / 2, y + h / 2, ORANGE, h * 0.20)
  local texte = string.format("%02d:%02d", d.hour, d.min)
  centre(texte, cx, y, ajuste(texte, h * 0.85, w * 0.86), BLANC)
end

-- Aiguille aux deux bouts arrondis
local function aiguille(cx, cy, angle, debut, fin, largeur, tex, c)
  trait(cx, cy, angle, debut, fin, largeur, tex)
  local a = math.rad(angle)
  local sx, sy = math.sin(a), -math.cos(a)
  disque(cx + sx * fin,   cy + sy * fin,   largeur / 2, c)
  disque(cx + sx * debut, cy + sy * debut, largeur / 2, c)
end

local function aiguilles(cx, cy, R, d)
  local m = d.min + d.sec / 60
  local h = (d.hour % 12) + m / 60

  aiguille(cx, cy, h * 30, -R * 0.10, R * 0.50, R * 0.075, tex_bleu, BLEU)
  aiguille(cx, cy, m * 6,  -R * 0.12, R * 0.78, R * 0.035, tex_bleu, BLEU)
  disque(cx, cy, R * 0.07, BLEU)

  if trotteuse then
    aiguille(cx, cy, d.sec * 6, -R * 0.20, R * 0.86, R * 0.012, tex_rouge, ROUGE)
    disque(cx, cy, R * 0.035, ROUGE)
  end
end

------------------------------------------------------------------------
-- Tuile date (haut gauche) : jour, quantieme, mois, annee
------------------------------------------------------------------------

-- Les 4 lignes forment un bloc centre verticalement : meme marge en haut et
-- en bas. Les lettres visibles occupent environ 78 % de la taille du texte.
local VISIBLE = 0.78

local function tuile_date(x1, y1, x2, y2, d)
  tuile(x1, y1, x2, y2)
  local h, xc, larg = y2 - y1, (x1 + x2) / 2, (x2 - x1) * 0.88
  local lignes = {
    {JOURS[d.wday],    ajuste(JOURS[d.wday], h * 0.179, larg)},
    {tostring(d.day),  ajuste("00",          h * 0.357, larg)},
    {MOIS[d.month],    ajuste(MOIS[d.month], h * 0.127, larg)},
    {tostring(d.year), ajuste("0000",        h * 0.127, larg)},
  }
  -- Mois et annee identiques : la plus petite des deux tailles
  local petit = math.min(lignes[3][2], lignes[4][2])
  lignes[3][2], lignes[4][2] = petit, petit
  local ecarts = {h * 0.09, h * 0.09, h * 0.06}

  local total = ecarts[1] + ecarts[2] + ecarts[3]
  for _, l in ipairs(lignes) do total = total + l[2] * VISIBLE end
  local y = y1 + (h - total) / 2
  for i, l in ipairs(lignes) do
    local v = l[2] * VISIBLE
    centre(l[1], xc, y + v / 2, l[2], BLANC)
    y = y + v + (ecarts[i] or 0)
  end
end

------------------------------------------------------------------------
-- Tuile meteo (haut, a cote de la date) : icones dessinees en unites,
-- environ 46 x 46
------------------------------------------------------------------------

local function nuage(x, y, k, c, tex)
  disque(x - 9 * k, y + 2 * k, 8 * k, c)
  disque(x + 1 * k, y - 4 * k, 11 * k, c)
  disque(x + 11 * k, y + 2 * k, 8 * k, c)
  tex:draw(x - 9 * k, y + 2 * k, x + 11 * k, y + 10 * k)
end

local function soleil(x, y, k)
  for i = 0, 7 do
    local a = math.rad(i * 45)
    local sx, sy = math.sin(a), -math.cos(a)
    barre(x + sx * 18 * k, y + sy * 18 * k, x + sx * 23 * k, y + sy * 23 * k,
          3.6 * k, tex_soleil, SOLEIL)
  end
  disque(x, y, 13 * k, SOLEIL)
end

local function lune(x, y, k)
  disque(x, y, 13 * k, SOLEIL, {0.45, -0.35, 0.85})
end

local ICONES = {
  soleil = function(x, y, k) soleil(x, y, k) end,
  lune   = function(x, y, k) lune(x, y, k) end,
  eclaircies = function(x, y, k)
    soleil(x + 7 * k, y - 8 * k, k * 0.7)
    nuage(x - 3 * k, y + 6 * k, k, BLANC, tex_blanc)
  end,
  eclaircies_nuit = function(x, y, k)
    lune(x + 7 * k, y - 8 * k, k * 0.75)
    nuage(x - 3 * k, y + 6 * k, k, BLANC, tex_blanc)
  end,
  nuageux = function(x, y, k)
    nuage(x + 6 * k, y - 6 * k, k * 0.75, NUAGE, tex_nuage)
    nuage(x - 4 * k, y + 6 * k, k, BLANC, tex_blanc)
  end,
  pluie = function(x, y, k)
    nuage(x, y - 6 * k, k, BLANC, tex_blanc)
    for _, dx in ipairs{-12, 0, 12} do
      barre(x + dx * k, y + 9 * k, x + (dx - 4) * k, y + 20 * k, 3 * k, tex_goutte, GOUTTE)
    end
  end,
  neige = function(x, y, k)
    nuage(x, y - 6 * k, k, BLANC, tex_blanc)
    for _, p in ipairs{{-12, 12}, {0, 12}, {12, 12}, {-6, 20}, {6, 20}} do
      disque(x + p[1] * k, y + p[2] * k, 2.6 * k, BLANC)
    end
  end,
  orage = function(x, y, k)
    nuage(x, y - 6 * k, k, NUAGE, tex_nuage)
    local z = {{3, 3}, {-4, 12}, {4, 12}, {-3, 22}}
    for i = 1, 3 do
      barre(x + z[i][1] * k, y + z[i][2] * k, x + z[i + 1][1] * k, y + z[i + 1][2] * k,
            3.4 * k, tex_soleil, SOLEIL)
    end
  end,
  brouillard = function(x, y, k)
    for i, dy in ipairs{-12, -4, 4, 12} do
      local dx = (i % 2 == 0) and 4 or -4
      barre(x + (dx - 16) * k, y + dy * k, x + (dx + 16) * k, y + dy * k, 4.4 * k, tex_nuage, NUAGE)
    end
  end,
}

local function meteo_valide()
  return meteo and meteo.maj and os.time() - meteo.maj < METEO_PERIMEE
end

-- Icone en haut, temperature en dessous, centrees dans la tuile.
-- Le symbole degre est dessine (anneau) : la police ne l'affiche pas sur le Pi.
local function tuile_meteo(x1, y1, x2, y2)
  tuile(x1, y1, x2, y2)
  if not meteo_valide() or not meteo.temperature then return end
  local dessin = ICONES[meteo.icone] or ICONES.nuageux
  local temp = string.format("%d", math.floor(meteo.temperature + 0.5))
  local h, xc = y2 - y1, (x1 + x2) / 2

  local k = math.min(h * 0.0125, (x2 - x1) * 0.62 / 46)
  dessin(xc, y1 + h * 0.36, k)

  local taille = h * 0.31
  local total = font:width(temp, taille) + taille * 0.30
  if total > (x2 - x1) * 0.86 then
    taille = taille * (x2 - x1) * 0.86 / total
    total = (x2 - x1) * 0.86
  end
  local xt = xc - total / 2
  local yt = y1 + h * 0.80 - taille / 2
  font:write(xt, yt, temp, taille, 1, 1, 1, 1)
  local rd = taille * 0.11
  disque(xt + font:width(temp, taille) + taille * 0.04 + rd, yt + taille * 0.22, rd, BLANC, {0, 0, 0.55})
end

------------------------------------------------------------------------
-- Tuile message (bas gauche)
------------------------------------------------------------------------

-- Decoupe le texte en lignes d'au plus "largeur" pixels
local function couper(texte, taille, largeur)
  local lignes, ligne = {}, ""
  for mot in texte:gmatch("%S+") do
    local essai = ligne == "" and mot or ligne .. " " .. mot
    if ligne ~= "" and font:width(essai, taille) > largeur then
      lignes[#lignes + 1] = ligne
      ligne = mot
    else
      ligne = essai
    end
  end
  if ligne ~= "" then lignes[#lignes + 1] = ligne end
  return lignes
end

-- Messages actifs a la date du jour ("AAAA-MM-JJ"), dans l'ordre de la liste
local function messages_du_jour(jour)
  local actifs = {}
  for _, m in ipairs(messages) do
    if (not m.debut or m.debut <= jour) and (not m.fin or jour <= m.fin) then
      actifs[#actifs + 1] = m.texte
    end
  end
  return actifs
end

-- Decoupage du texte, calcule une fois par message et par taille de tuile
local mise_en_page_messages = {}

local function mise_en_page_message(texte, larg, haut, pad)
  local cle = texte .. "|" .. larg .. "|" .. haut
  local m = mise_en_page_messages[cle]
  if m then return m end
  local taille = HEIGHT * 0.14
  local lignes
  for _ = 1, 30 do
    lignes = couper(texte, taille, larg - 2 * pad)
    local plus_large = 0
    for _, l in ipairs(lignes) do plus_large = math.max(plus_large, font:width(l, taille)) end
    if #lignes <= 3 and plus_large <= larg - 2 * pad and #lignes * taille * 1.15 <= haut - 2 * pad then
      break
    end
    taille = taille * 0.92
  end
  m = {lignes = lignes, taille = taille}
  mise_en_page_messages[cle] = m
  return m
end

-- Texte blanc qui s'adapte a la tuile (3 lignes au plus). Plusieurs messages
-- actifs : un toutes les 8 secondes, avec un fondu rapide entre deux messages.
local DUREE_MESSAGE = 8
local FONDU_MESSAGE = 0.25

local function tuile_message(x1, y1, x2, y2, jour)
  tuile(x1, y1, x2, y2)
  local actifs = messages_du_jour(jour)
  if #actifs == 0 then return end

  local larg, haut = x2 - x1, y2 - y1
  local pad = HEIGHT * 0.03
  local n = #actifs
  local tour = math.floor(sys.now() / DUREE_MESSAGE)
  local s = sys.now() - tour * DUREE_MESSAGE
  local a = 1
  if n > 1 then
    -- le texte s'efface en fin de tour, le suivant reapparait
    a = math.min(1, s / FONDU_MESSAGE, (DUREE_MESSAGE - s) / FONDU_MESSAGE)
  end

  local m = mise_en_page_message(actifs[tour % n + 1], larg, haut, pad)
  local bloc = #m.lignes * m.taille * 1.15
  local y0 = y1 + (haut - bloc) / 2
  for i, l in ipairs(m.lignes) do
    centre(l, x1 + larg / 2, y0 + (i - 0.5) * m.taille * 1.15, m.taille, BLANC, a)
  end
end

------------------------------------------------------------------------

function node.render()
  gl.clear(FOND[1], FOND[2], FOND[3], 1)

  -- Heure locale
  local t   = os.time()
  local utc = os.date("!*t", t)
  local d   = os.date("!*t", t + decalage(utc))

  -- Cadran a droite, sur toute la hauteur
  local R  = HEIGHT * 0.418
  local cx = WIDTH - HEIGHT * 0.485
  local cy = HEIGHT / 2

  -- Tuiles a gauche : date et meteo en haut, message en bas
  local mx, my = HEIGHT * 0.04, HEIGHT * 0.077
  local gx = HEIGHT * 0.026
  local xd = cx - R * 1.067 - mx
  local xm = (mx + xd) / 2
  local yh = (HEIGHT - my) / 2                 -- bas de la rangee du haut
  local yb = yh + my                           -- haut de la tuile message

  tuile_date(mx, my, xm - gx / 2, yh, d)
  tuile_meteo(xm + gx / 2, my, xd, yh)
  tuile_message(mx, yb, xd, HEIGHT - my, string.format("%04d-%02d-%02d", d.year, d.month, d.day))

  cadran(cx, cy, R)
  logo_cadran(cx, cy, R)
  if horloge_digitale then heure_digitale(cx, cy, R, d) end
  aiguilles(cx, cy, R, d)
end
