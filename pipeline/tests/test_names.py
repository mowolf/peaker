import pytest

from peaker_pipeline.peaks.model import Peak
from peaker_pipeline.peaks.names import choose_display_name, is_latin, transliterate, transliterate_devanagari


@pytest.mark.parametrize("dev,latin", [("मनास्लु", "Manaslu"), ("मकालु", "Makalu"), ("गौरीशंकर", "Gaurishankar"),
                                       ("लाङटाङ लिरुङ", "Langtang Lirung"), ("अन्नपूर्ण", "Annapurna"),
                                       ("सगरमाथा", "Sagaramatha"), ("धौलागिरी", "Dhaulagiri"), ("पोखरा", "Pokhara")])
def test_devanagari(dev, latin):
    assert transliterate_devanagari(dev) == latin


def test_mixed_scripts_prefer_devanagari():
    assert transliterate("मकालु 马卡鲁峰") == "Makalu"
    assert is_latin(transliterate("希夏邦马峰"))


def test_choose_display_name():
    everest = Peak(27.99, 86.93, name="珠穆朗玛峰 ཇོ་མོ་གླང་མ། सगरमाथा", names={"en": "Mount Everest"})
    assert choose_display_name(everest) == ("Mount Everest", "珠穆朗玛峰 ཇོ་མོ་གླང་མ། सगरमाथा")
    merged = Peak(28.5, 84.5, name="मनास्लु", alt_names=["Manaslu"])  # GeoNames name merged in
    assert choose_display_name(merged) == ("Manaslu", "मनास्लु")
    alone = Peak(28.5, 84.5, name="गौरीशंकर")
    assert choose_display_name(alone) == ("Gaurishankar", "गौरीशंकर")
    assert choose_display_name(Peak(46, 7, name="Mönch")) == ("Mönch", None)
