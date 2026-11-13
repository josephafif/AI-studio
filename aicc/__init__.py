"""AI Control Center – lokal kontrollpanel för att skapa, träna och testa AI-modeller.

Paketet är uppdelat i tre lager som hålls åtskilda:

* ``aicc.ui``      – det grafiska gränssnittet (HTML/CSS/JS, ingen affärslogik)
* ``aicc.core``    – modell-, dataset- och körningshantering (importerar aldrig PyTorch)
* ``aicc.engine``  – tokenizer, träningsprocess och inferens (PyTorch)

``aicc.server`` är det tunna HTTP-lagret som kopplar gränssnittet till ``core``.
Träning körs alltid i en egen process (``aicc.engine.train_worker``).
"""

__version__ = "1.0.0"
