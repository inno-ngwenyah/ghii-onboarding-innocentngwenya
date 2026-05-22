# ------------------------------------------------------------------------------------
# MySQL connectivity test
# ------------------------------------------------------------------------------------
from sqlalchemy import create_engine, text
from dotenv import load_dotenv
import os

load_dotenv()

engine = create_engine(
    "mysql+pymysql://{user}:{pw}@{host}:{port}/{db}".format(
        user=os.environ["OMRS_DB_USER"],
        pw=os.environ["OMRS_DB_PASSWORD"],
        host=os.environ.get("OMRS_DB_HOST", "localhost"),
        port=os.environ.get("OMRS_DB_PORT", "3306"),
        db=os.environ["OMRS_DB_NAME"],
    ),
    pool_pre_ping=True,
)

try:
    with engine.connect() as connection:
        result = connection.execute(text("SELECT version()"))
        print("Connection successful!")
        print(f"MySQL version: {result.fetchone()[0]}")
except Exception as e:
    print(f"Error: {e}")