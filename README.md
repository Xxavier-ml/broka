# BROKA — AI-Powered Marketplace

> The fairest way to buy and sell in Kenya. BROKA uses AI to broker transparent, win-win deals.

---

## What is BROKA?

BROKA is a mobile marketplace where every transaction is mediated by an AI broker powered by **Llama 3.3 70B via Groq**. Instead of haggling blindly, buyers and sellers negotiate through BROKA — an impartial AI that protects both parties and works toward a fair deal.

**3% transaction fee** covers escrow protection, fraud prevention, and verified payments.

---

## Stack

| Layer | Technology |
|---|---|
| Mobile app | Flutter (Dart) |
| Backend API | FastAPI (Python) + async SQLAlchemy |
| AI broker | Groq — llama-3.3-70b-versatile |
| Edge layer | Hono (Node.js) on Render |
| Auth | JWT |
| CI/CD | GitHub Actions + Codemagic |

---

## Project Structure

```
broka/
├── backend/
│   ├── api/
│   │   ├── routers/
│   │   │   ├── negotiate.py   # AI broker engine
│   │   │   ├── listings.py    # Marketplace listings
│   │   │   ├── auction.py     # Auction bidding
│   │   │   ├── auth.py        # JWT auth
│   │   │   └── deal.py        # Deal finalisation
│   │   ├── database.py        # SQLAlchemy models
│   │   ├── schemas.py
│   │   └── security.py
│   ├── main.py
│   ├── requirements.txt
│   └── Dockerfile
├── flutter_app/
│   └── lib/
│       ├── main.dart           # App entry + design tokens
│       ├── models/             # Listing, Message, Bid
│       ├── services/           # API service layer
│       └── screens/
│           ├── splash_screen.dart
│           ├── auth_screen.dart
│           ├── home_screen.dart
│           ├── sell_screen.dart
│           ├── broker_screen.dart    # Free-form AI chat
│           ├── negotiation_screen.dart  # Listing-specific negotiation
│           ├── inbox_screen.dart    # All active threads
│           ├── auction_screen.dart
│           └── profile_screen.dart
├── src/index.js                # Hono edge health layer
└── .github/workflows/          # CI/CD
```

---

## Getting Started

### Backend

```bash
cd backend
pip install -r requirements.txt
cp ../.env.example .env   # fill in GROQ_API_KEY and DATABASE_URL
uvicorn main:app --reload
```

### Flutter app

```bash
cd flutter_app
flutter pub get
flutter run
```

Set `API_URL` at build time to point to your backend:

```bash
flutter run --dart-define=API_URL=https://your-backend.onrender.com
```

---

## Environment Variables

| Variable | Description |
|---|---|
| `GROQ_API_KEY` | Your Groq API key |
| `DATABASE_URL` | PostgreSQL connection string |
| `SECRET_KEY` | JWT signing secret |

---

## Deployment

- **Backend**: Render (`render.yaml` included)
- **Flutter**: Codemagic (`codemagic.yaml` included)

---

## Roadmap

- [ ] WebSocket real-time negotiation updates
- [ ] GPS-based nearby listings
- [ ] Escrow payment integration (M-Pesa)
- [ ] Trust score system
- [ ] Multilingual AI (English + Swahili)
- [ ] Push notifications for deal updates
