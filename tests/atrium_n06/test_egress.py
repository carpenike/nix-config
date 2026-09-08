import pytest

from egress import render


def policy():
    return {
        "schema_version": 1,
        "isolated": True,
        "service_uid": 11001,
        "destinations": {
            "gateway": {
                "hosts": ["litellm.atrium.invalid"],
                "ports": [443],
                "kind": "gateway",
            },
        },
    }


def test_exact_address_policy_has_no_blanket_internet_or_established_flow_escape():
    rules = render(policy(), {"gateway": ["10.42.0.2"]})
    assert "meta skuid 11001 ct direction reply counter accept" in rules
    assert "ip daddr 10.42.0.2 tcp dport { 443 }" in rules
    assert "reject with icmpx type admin-prohibited" in rules
    assert "ct state established" not in rules
    assert "0.0.0.0/0" not in rules and "flush ruleset" not in rules


@pytest.mark.parametrize(
    "bindings",
    [
        {},
        {"gateway": []},
        {"gateway": ["0.0.0.0/0"]},
        {"gateway": ["::1"]},
        {"gateway": ["127.0.0.1"]},
        {"gateway": ["10.1.2.3"], "foreign": ["10.1.2.4"]},
    ],
)
def test_unknown_or_unbounded_destinations_are_refused(bindings):
    with pytest.raises(ValueError):
        render(policy(), bindings)


@pytest.mark.parametrize("uid", [0, 999, True])
def test_setup_does_not_select_root_or_an_ambiguous_identity(uid):
    value = policy()
    value["service_uid"] = uid
    with pytest.raises(ValueError, match="uid"):
        render(value, {"gateway": ["10.1.2.3"]})
