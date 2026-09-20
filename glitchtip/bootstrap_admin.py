"""Create or re-sync the GlitchTip admin from GLITCHTIP_ADMIN_EMAIL / GLITCHTIP_ADMIN_PASSWORD.

Run by the glitchtip_migrate one-shot service after `manage.py migrate`, via
    python manage.py shell -c "exec(open('/bootstrap/bootstrap_admin.py').read())"
Idempotent: a missing admin is created, an existing one is made a superuser again
and gets the password from the environment, so changing the password in .env and
redeploying is enough to rotate it. Open signup is closed separately with
ENABLE_USER_REGISTRATION=false; superusers can always create organizations.
"""
import os

from allauth.account.models import EmailAddress
from django.contrib.auth import get_user_model

User = get_user_model()
email = os.environ["GLITCHTIP_ADMIN_EMAIL"].strip().lower()
password = os.environ["GLITCHTIP_ADMIN_PASSWORD"]

user = User.objects.filter(email=email).first()
if user is None:
    user = User.objects.create_superuser(email=email, password=password)
    action = "created"
else:
    user.is_active = user.is_staff = user.is_superuser = True
    user.set_password(password)
    user.save()
    action = "updated"
EmailAddress.objects.update_or_create(
    user=user, email=email, defaults={"verified": True, "primary": True}
)
print(f"glitchtip admin {email}: {action}")
