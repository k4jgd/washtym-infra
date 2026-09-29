"""Security-focused Flask AppBuilder configuration for Airflow's FAB auth manager."""

from flask_appbuilder.const import AUTH_DB


AUTH_TYPE = AUTH_DB
AUTH_USER_REGISTRATION = False
WTF_CSRF_ENABLED = True

# This deployment is reachable only through the trusted office LAN over HTTP.
SESSION_COOKIE_SECURE = False
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = "Lax"
