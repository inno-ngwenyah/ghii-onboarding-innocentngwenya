# --------------------------------------------------------------------------------
# PostgreSQL connectivity test
# --------------------------------------------------------------------------------
from sqlalchemy import create_engine, text
from dotenv import load_dotenv
import os

load_dotenv()

def test_pg_connection():
    print("Testing PostgreSQL connection.....")

    try:
        engine = create_engine(
            "postgresql+psycopg2://{user}:{pw}@{host}:{port}/{db}".format(
                user=os.environ["PG_USER"],
                pw=os.environ["PG_PASSWORD"],
                host=os.environ.get("PG_HOST", "localhost"),
                port=os.environ.get("PG_PORT", "5432"),
                db=os.environ["PG_DB"],
            ),
            pool_pre_ping=True,
        )

        with engine.connect() as conn:

            # Test 1 — basic connectivity
            result = conn.execute(text("SELECT version()"))
            print(f"\n  ✓ Connected successfully")
            print(f"  PostgreSQL version: {result.fetchone()[0]}")

            # Test 2 — check database name
            result = conn.execute(text("SELECT current_database()"))
            print(f"  Current database : {result.fetchone()[0]}")

            # Test 3 — check user permissions
            result = conn.execute(text("SELECT current_user"))
            print(f"  Connected as user: {result.fetchone()[0]}")

            # Test 4 — check we can create tables
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS _connection_test (
                    id SERIAL PRIMARY KEY,
                    test_col TEXT
                )
            """))
            conn.execute(text("DROP TABLE IF EXISTS _connection_test"))
            conn.commit()
            print(f"  ✓ Create/drop table permission confirmed")

        print("\n  All checks passed — PostgreSQL is ready for loading.\n")

    except KeyError as e:
        print(f"\n  ✗ Missing environment variable: {e}")
        print("    Check your .env file has PG_USER, PG_PASSWORD, PG_DB defined.")

    except Exception as e:
        print(f"\n  ✗ Connection failed: {e}")

if __name__ == "__main__":
    test_pg_connection()