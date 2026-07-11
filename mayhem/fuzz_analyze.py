#! /usr/bin/env python3
import atheris
import sys
import fuzz_helpers

with atheris.instrument_imports(include=["pytype"]):
    from pytype.pyi import parser


options = parser.PyiOptions(python_version=(3, 7))
def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        parser.parse_string(fdp.ConsumeRemainingString(), filename="<string>", options=options)
    except parser.ParseError:
        return -1
    except ValueError as e:
        if 'null bytes' in str(e):
            return -1
        raise e




def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
