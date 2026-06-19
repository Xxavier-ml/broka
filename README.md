# BROKA - AI-Powered Marketplace

> The fairest way to buy and sell in Kenya. BROKA uses AI to broker transparent, win-win deals.

---

## What is BROKA?

BROKA is a mobile marketplace where every transaction is mediated by an AI broker powered by **Gemini 2.0 Flash** (primary, for strong multilingual African-language support) with **Llama 3.3 70B via Groq** as an automatic fallback. Instead of haggling blindly, buyers and sellers negotiate through BROKA - an impartial AI that protects both parties and works toward a fair deal.

**3% transaction fee** covers escrow protection, fraud prevention, and verified payments.

---

## Stack

| Layer | Technology |
|---|---|
| Mobile app | Flutter (Dart) |
| Backend API | FastAPI (Python) + async SQLAlchemy |
| AI broker | Gemini 2.0 Flash (primary) · Groq llama-3.3-70b-versatile (fallback) |
| Edge layer | Hono (Node.js) on Render |
| Auth | JWT + `local_auth` biometrics |
| CI/CD | GitHub Actions + Codemagic |

---

## Key Features

### Multi-Step Registration
Account creation is split into 4 clean screens:
1. **Basic Info** - name, nickname, phone, email, password
2. **Profile Selfie** - front camera only (no gallery upload allowed)
3. **BROKA Biometrics** - fresh fingerprint or face scan captured live, NOT reading stored device data
4. **Confirmation** - review and activate

### BROKA Biometric Security
- Biometrics are captured **live during setup** using `local_auth` with `biometricOnly: true`
- This is explicitly **not** using stored device biometric data - the user physically scans their finger or face
- Required to approve payments (M-Pesa integration in v3)
- Gracefully handles: no hardware, hardware present but not enrolled, full enrollment

### User Search
- Search any trader by name, nickname, or email
- Results show: rating, completed deals, join date, location (only if user opted in)
- Location privacy toggle in Profile → Settings

### M-Pesa Ready (v3)
The backend `Deal` model and payment flow are structured to accept an M-Pesa transaction reference. Next version will add:
- STK Push on deal agreement
- Biometric confirmation before payment release
- Escrow hold via M-Pesa B2B paybill

---

## Project Structure

```
broka/
├── backend/
│   ├── api/
│   │   ├── routers/
│   │   │   ├── negotiate.py      # AI broker engine (Groq)
│   │   │   ├── listings.py       # Marketplace listings
│   │   │   ├── auction.py        # Auction bidding
│   │   │   ├── auth.py           # JWT auth, biometric enroll, user search
│   │   │   └── deal.py           # Deal finalisation
│   │   ├── database.py           # SQLAlchemy models
│   │   ├── schemas.py
│   │   └── security.py
│   ├── main.py
│   ├── requirements.txt
│   └── Dockerfile
├── flutter_app/
│   └── lib/
│       ├── main.dart                   # App entry + design tokens
│       ├── models/                     # Listing, Message, Bid
│       ├── services/api_service.dart   # API service layer
│       └── screens/
│           ├── splash_screen.dart
│           ├── auth_screen.dart          # 4-step registration + login
│           ├── selfie_camera_screen.dart # Front-camera selfie (step 2)
│           ├── home_screen.dart
│           ├── sell_screen.dart
│           ├── broker_screen.dart        # Free-form AI chat
│           ├── negotiation_screen.dart   # Listing-specific negotiation
│           ├── inbox_screen.dart         # All active threads
│           ├── auction_screen.dart
│           ├── profile_screen.dart
│           ├── search_screen.dart        # User search with privacy
│           ├── user_profile_screen.dart  # Public trader profile
│           ├── product_screen.dart
│           ├── listing_map_screen.dart
│           ├── ai_assistant_screen.dart
│           └── zeno_screen.dart        # Zeno AI advisor (formerly xxeno)
├── src/index.js                    # Hono edge health layer
└── .github/workflows/              # CI/CD
```

---

## Getting Started

### Backend

```bash
cd backend
pip install -r requirements.txt
cp ../.env.example .env   # fill in GROQ_API_KEY and SECRET_KEY
uvicorn main:app --reload
```

### Flutter app

```bash
cd flutter_app
flutter pub get
flutter run --dart-define=API_URL=https://your-backend.onrender.com
```

---

## Environment Variables

| Variable | Description |
|---|---|
| `GEMINI_API_KEY` | Your Google Gemini API key (primary AI broker; from aistudio.google.com) |
| `GROQ_API_KEY` | Your Groq API key (automatic fallback; from console.groq.com) |
| `DATABASE_URL` | PostgreSQL connection string (Render injects automatically) |
| `SECRET_KEY` | JWT signing secret (generate: `openssl rand -hex 32`) |
| `TOKEN_EXPIRE_MINUTES` | JWT expiry, default 60 |

---

## Deployment

- **Backend**: Render (`render.yaml` included)
- **Flutter**: Codemagic (`codemagic.yaml` included)

---

## Roadmap

- [x] Multi-step registration (selfie, biometrics, confirmation)
- [x] BROKA-specific fresh biometric capture (not stored device data)
- [x] User search with location privacy controls
- [x] Public trader profile (rating, deals, listings)
- [ ] WebSocket real-time negotiation updates
- [ ] GPS-based nearby listings
- [ ] **M-Pesa escrow payment integration** (v3 - biometric-confirmed)
- [ ] Trust score system
- [ ] Push notifications for deal updates

## v2.2 Production Hardening (new)

### Backend ENV vars
- `ALLOWED_ORIGINS` - comma-separated list, e.g. `https://broka.app,https://www.broka.app`. Defaults to `*` for dev.
- `OPENAI_API_KEY` - enables `/stt/transcribe` (multilingual Whisper).
- `ADMIN_BOOTSTRAP_EMAIL` - email of the user to promote to admin via `POST /admin/bootstrap`.
- `MPESA_*` - unchanged (see `routers/mpesa.py` docstring). Daraja STK timestamp now derived from UTC+3 (Nairobi) so it works on any host timezone.

### New endpoints
- `POST /stt/transcribe` - multipart `file` + form `language` → `{text}`
- `POST /escrow/confirm-delivery/{deal_id}` - buyer releases held funds → seller
- `POST /escrow/open-dispute/{deal_id}` - freezes funds, then full flow lives in `/disputes/*`
- `GET  /escrow/state/{deal_id}` - escrow state machine view
- `POST /admin/bootstrap` - promote `ADMIN_BOOTSTRAP_EMAIL` to admin (idempotent)
- `GET  /admin/summary` - users, deals, disputes, mpesa rollup
- `GET  /admin/users` · `POST /admin/users/{id}/promote|demote|verify`
- `GET  /admin/disputes` · `GET /admin/transactions`

### Escrow lifecycle
`agreed → paid (funds held) → released | disputed → refunded` with timestamped audit columns on `deals`.
