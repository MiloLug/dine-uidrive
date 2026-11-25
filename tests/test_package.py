import uidrive


def test_agent_src_holds_the_cmake_project():
    assert uidrive.agent_src().is_absolute()
    assert (uidrive.agent_src() / "CMakeLists.txt").is_file()
