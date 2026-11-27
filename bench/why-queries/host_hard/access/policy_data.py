"""The site policy as shipped. Sites can replace this text with their own."""

DEFAULT_POLICY = """
# ---------------------------------------------------------------- zones
[zones]
names = lobby, office, lab, server, loading, roof

[roles]
engineer   = office
lab_tech   = office, lab
facilities = office, loading, roof, server
security   = lobby, office, lab, server, loading, roof
exec       = office

[training]
lab    = lab_safety
server = server_access
roof   = fall_protection

[restrictions]
second_factor_off_hours = lab, server, roof
no_visitors = server, roof

# ---------------------------------------------------------------- time
[hours]
business_days = mon-fri
business = 07:00-19:00
night = 22:00-06:00

[reporting]
# Hours used for the weekly occupancy report (not for access decisions).
report_days = mon-sun
report_window = 06:00-20:00

# ---------------------------------------------------------------- people
[contracts]
expiring_within_days = 7
renewal_reminder_days = 30

[alerts]
cooldown_seconds = 120
"""
