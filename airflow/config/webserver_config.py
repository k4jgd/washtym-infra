"""Security-focused Flask AppBuilder configuration for Airflow's FAB auth manager."""

from flask_appbuilder.const import AUTH_DB


AUTH_TYPE = AUTH_DB
AUTH_USER_REGISTRATION = False
WTF_CSRF_ENABLED = True

# TLS terminates at the shared Caddy reverse proxy. ProxyFix is enabled through
# AIRFLOW__FAB__ENABLE_PROXY_FIX so Flask recognizes the original HTTPS scheme.
SESSION_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = "Lax"

