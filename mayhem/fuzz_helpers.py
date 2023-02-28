# Atheris fuzzing utilities written by Bailey Capuano
import io
import tempfile
import atheris
import contextlib
from typing import List, Set, Dict, Tuple, Any


def _handle_type(fdp: atheris.FuzzedDataProvider, ty_queue: List[type]) -> Any:
    """
    Handles the fuzzing of a single type.
    :param fdp: FuzzedDataProvider object
    :param ty_queue: The current stack of types to be used for fuzzing
    :return: The fuzzed element
    """
    if not ty_queue:
        return None
    ty = ty_queue.pop(0)
    if ty is bytes:
        return fdp.ConsumeBytes(fdp.ConsumeIntInRange(0, 100))
    elif ty is bytearray:
        return bytearray(fdp.ConsumeBytes(fdp.ConsumeIntInRange(0, 100)))
    elif ty is str:
        return fdp.ConsumeUnicodeNoSurrogates(fdp.ConsumeIntInRange(0, 100))
    elif ty is float:
        return fdp.ConsumeRegularFloat()
    elif ty is bool:
        return fdp.ConsumeBool()
    elif ty is int:
        return fdp.ConsumeInt(4)
    elif ty is dict:
        return build_fuzz_dict(fdp, ty_queue)
    elif ty is list:
        return build_fuzz_list(fdp, ty_queue)
    elif ty is set:
        return build_fuzz_set(fdp, ty_queue)
    elif ty is tuple:
        return build_fuzz_tuple(fdp, ty_queue)
    else:
        return None


def build_fuzz_list(fdp: atheris.FuzzedDataProvider, ty_queue: List[type]) -> List[Any]:
    """
    Builds a list with fuzzer-defined elements.
    :param fdp: FuzzedDataProvider object
    :param ty_queue: The current stack of types to be used for fuzzing
    :return: The list
    """
    if not ty_queue:
        return []
    elem_count = fdp.ConsumeIntInRange(1, 5)
    gen_list = []

    for _ in range(elem_count):
        passed_queue = ty_queue.copy()
        elem = _handle_type(fdp, passed_queue)
        if elem is not None:
            gen_list.append(elem)
    ty_queue.pop(0)  # Pop elem type

    return gen_list


def build_fuzz_set(fdp: atheris.FuzzedDataProvider, ty_queue: List[type]) -> Set[Any]:
    """
    Builds a set with fuzzer-defined elements.
    :param fdp: FuzzedDataProvider object
    :param ty_queue: The current stack of types to be used for fuzzing
    :return: The set
    """
    if not ty_queue:
        return set()
    ty_queue.insert(0, list)

    fuzz_list = _handle_type(fdp, ty_queue)
    return set(fuzz_list)


def build_fuzz_tuple(fdp: atheris.FuzzedDataProvider, ty_queue: List[type]) -> Tuple[Any]:
    """
    Builds a tuple with fuzzer-defined elements.
    :param fdp: FuzzedDataProvider object
    :param ty_queue: The current stack of types to be used for fuzzing
    :return: The tuple
    """
    if not ty_queue:
        return tuple()
    ty_queue.insert(0, list)

    fuzz_list = _handle_type(fdp, ty_queue)
    return tuple(fuzz_list)


def build_fuzz_dict(fdp: atheris.FuzzedDataProvider, ty_queue: List[type]) -> Dict[Any, Any]:
    """
    Builds a dictionary with fuzzer-defined keys and values.
    :param fdp: FuzzedDataProvider object
    :param ty_queue: The current stack of types to be used for fuzzing
    :return: The dictionary
    """
    if not ty_queue:
        return {}

    ty_queue.insert(0, list)  # handle key
    key_list = _handle_type(fdp, ty_queue)
    ty_queue.insert(0, list)  # handle key
    val_list = _handle_type(fdp, ty_queue)

    # Shrink lists to match
    if len(key_list) > len(val_list):
        key_list = key_list[:len(val_list)]
    elif len(val_list) > len(key_list):
        val_list = val_list[:len(key_list)]

    return dict(zip(key_list, val_list))


class EnhancedFuzzedDataProvider(atheris.FuzzedDataProvider):
    def ConsumeRandomBytes(self) -> bytes:
        return self.ConsumeBytes(self.ConsumeIntInRange(0, self.remaining_bytes()))

    def ConsumeRandomString(self) -> str:
        return self.ConsumeUnicodeNoSurrogates(self.ConsumeIntInRange(0, self.remaining_bytes()))

    def ConsumeRemainingString(self) -> str:
        return self.ConsumeUnicodeNoSurrogates(self.remaining_bytes())

    def ConsumeRemainingBytes(self) -> bytes:
        return self.ConsumeBytes(self.remaining_bytes())

    @contextlib.contextmanager
    def ConsumeMemoryFile(self, all_data: bool = False, as_bytes: bool = True) -> io.BytesIO:
        if all_data:
            file_data = self.ConsumeRemainingBytes() if as_bytes else self.ConsumeRemainingString()
        else:
            file_data = self.ConsumeRandomBytes() if as_bytes else self.ConsumeRandomString()

        file = io.BytesIO(file_data) if as_bytes else io.StringIO(file_data)
        yield file
        file.close()

    @contextlib.contextmanager
    def ConsumeTemporaryFile(self, suffix: str, all_data: bool = False, as_bytes: bool = True) -> io.StringIO:
        if all_data:
            file_data = self.ConsumeRemainingBytes() if as_bytes else self.ConsumeRemainingString()
        else:
            file_data = self.ConsumeRandomBytes() if as_bytes else self.ConsumeRandomString()

        mode = 'w+b' if as_bytes else 'w+'
        tfile = tempfile.NamedTemporaryFile(mode=mode, suffix=suffix)
        tfile.write(file_data)
        tfile.seek(0)
        tfile.flush()
        yield tfile.name
        tfile.close()
