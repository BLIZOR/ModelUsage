# ModelUsage

Menubar macOS pour suivre la consommation **Claude Code** de ton abonnement (Pro/Max) en temps réel — par modèle, avec les **vrais plafonds du forfait**, le coût équivalent API et des projections.

Natif Swift/SwiftUI, zéro dépendance, zéro Electron. Toutes les données restent sur ta machine.

## Ce que ça affiche

- **Session 5 h** : % officiel de l'abonnement (live, interpolé entre deux appels API), début · durée · reset, tokens consommés / plafond réel estimé / restants
- **Courbe « heart monitor »** du débit instantané (tok/min) avec allure 🚶 🚴 🚗 ✈️ 🚀
- **Par modèle** (Fable, Opus, Sonnet, Haiku…) : tokens et coût équivalent API du bloc courant
- **Prévision** : tokens restants, durée avant épuisement, badge « tiendra jusqu'au reset » / « épuisé avant »
- **Semaine** : % 7 jours officiel + projection « à ce rythme : plafond jeudi 18h »
- **Coûts équivalent API** : mois en cours vs prix de l'abonnement (« ×8.9 l'abonnement »), chart 14 jours, totaux 30 j / moyenne / fin de mois, top projets et top modèles du mois
- **Notifications système** à 80 % / 95 % de la session et quand la projection passe « épuisé avant le reset »
- Cadran % dans la menubar (couleur par seuil), ouverture au login, boot ~1 s (cache disque incrémental)

## Comment ça marche

- **Limites réelles** : endpoint OAuth officiel (`api.anthropic.com/api/oauth/usage`) avec le token de TON abonnement, lu dans le Keychain (posé par Claude Code). Aucun autre appel réseau.
- **Comptage par modèle** : lecture incrémentale des transcripts locaux `~/.claude/projects/**/*.jsonl` (dédup `message.id`+`requestId` — indispensable, chaque réponse apparaît en plusieurs lignes).
- **Plafond du forfait** : Anthropic ne publie pas de nombre de tokens ; il est estimé par `tokens comptés ÷ % officiel`, recalé à chaque appel API (60 s).
- Coûts = équivalent API (tarifs publics par modèle, cache write ×1.25/×2, cache read ×0.1) — informatif, l'abonnement est forfaitaire.

## Installation

```sh
git clone https://github.com/BLIZOR/ModelUsage && cd ModelUsage
./make-app.sh   # build + installe ~/Applications/ModelUsage.app + lance
```

Prérequis : macOS 14+, Xcode Command Line Tools, Claude Code connecté (le token vit dans le Keychain). Au premier lancement, macOS demande l'accès au trousseau (« Toujours autoriser ») et aux notifications.

## Notes

- **Polices** : l'UI utilise Netwa Neo si présente dans `Fonts/` (non incluse — police commerciale), sinon la police système. Rien à faire.
- L'endpoint usage **rate-limite vite** : l'app appelle strictement 1×/min et garde la dernière valeur en cas d'échec.
- Cache local : `~/Library/Application Support/ModelUsage/scan-cache.json`. Log de debug : `/tmp/modelusage.log`.
- `Attic/` : fonctionnalités en pause (panneau sessions/workflows, île notch, reprises, sessions programmées), non compilées.

## Licence

MIT
