"""Run once on first deploy: init DB, create admin user, print one-time password."""
import secrets, sys
import bcrypt
from privacypi_app import create_app
from privacypi_app.extensions import db
from privacypi_app.models import User

def main():
    app = create_app()
    with app.app_context():
        db.create_all()
        if not db.session.query(User).count():
            pw = secrets.token_urlsafe(16)
            u = User(
                username="admin",
                password_hash=bcrypt.hashpw(pw.encode(), bcrypt.gensalt()).decode(),
                is_admin=True,
                totp_enabled=False,
            )
            db.session.add(u)
            db.session.commit()
            print(f"=== PrivacyPi admin bootstrap ===")
            print(f"Username: admin")
            print(f"Password: {pw}")
            print(f"⚠ change password and enable TOTP after first login")
        else:
            print("admin already exists, skipping bootstrap")

if __name__ == "__main__":
    main()
