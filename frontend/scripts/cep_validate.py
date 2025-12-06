import datetime as _datetime
import json
import sys

try:
    from cep import Transferencia
    from cep.exc import CepError, TransferNotFoundError, CepNotAvailableError
except Exception as exc:  # pragma: no cover - import side effects only
    print(json.dumps({"valid": False, "error": f"cepmex missing or failed to import: {exc}"}))
    sys.exit(0)


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        fecha = _datetime.date.fromisoformat(payload["fecha"])
        transferencia = Transferencia.validar(
            fecha=fecha,
            clave_rastreo=payload["claveRastreo"],
            emisor=payload["emisor"],
            receptor=payload["receptor"],
            cuenta=payload["cuenta"],
            monto=int(payload["montoCentavos"]),
            pago_a_banco=bool(payload.get("pagoABanco", False)),
        )
        print(json.dumps({"valid": True, "transferencia": transferencia.to_dict()}))
    except (CepError, TransferNotFoundError, CepNotAvailableError) as exc:  # type: ignore[arg-type]
        print(json.dumps({"valid": False, "error": str(exc)}))
    except Exception as exc:  # pragma: no cover - debug path
        print(json.dumps({"valid": False, "error": f"Unhandled: {exc}"}))


if __name__ == "__main__":
    main()
