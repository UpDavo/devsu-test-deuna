"""Pruebas de la lógica de detección. No requieren AWS.

Ejecutar desde tarea-1-monitoreo-ecs/lambda:
    python -m unittest discover -s tests
"""

import os
import sys
import unittest
from datetime import UTC, datetime
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import capacity_monitor as cm  # noqa: E402

CFG = cm.Config(
    environment="production", sustain_seconds=300, recovery_seconds=600, renotify_seconds=1800
)
T0 = 1_800_000_000  # múltiplo de 60


def snap(
    desired, max_capacity=10, min_capacity=2, service="payments-processor", cluster="core", **kw
):
    return cm.ServiceSnapshot(
        cluster=cluster,
        service=service,
        min_capacity=min_capacity,
        max_capacity=max_capacity,
        desired=desired,
        running=desired,
        pending=0,
        tags=kw.pop("tags", {"owner": "payments", "criticality": "tier-1"}),
        **kw,
    )


def simulate(desired_by_minute, cfg=CFG):
    """Corre evaluate minuto a minuto y devuelve [(minuto, evento)]."""
    state, out = None, []
    for minute, desired in enumerate(desired_by_minute):
        state, events = cm.evaluate(snap(desired), state, T0 + minute * 60, cfg)
        out.extend((minute, e) for e in events)
    return out


class ClassifyTest(unittest.TestCase):
    def test_at_max(self):
        self.assertEqual(cm.classify(snap(10), CFG), cm.STATUS_AT_MAX)

    def test_warning_band_starts_at_80_percent(self):
        self.assertEqual(cm.classify(snap(7), CFG), cm.STATUS_OK)
        self.assertEqual(cm.classify(snap(8), CFG), cm.STATUS_WARNING)
        self.assertEqual(cm.classify(snap(9), CFG), cm.STATUS_WARNING)

    def test_fixed_size_service_never_alerts(self):
        self.assertEqual(cm.classify(snap(4, max_capacity=4, min_capacity=4), CFG), cm.STATUS_OK)


class EvaluateTest(unittest.TestCase):
    def test_short_spike_does_not_page(self):
        events = simulate([5, 10, 10, 10, 5] + [5] * 12)
        self.assertEqual([e for _, e in events], ["max_reached", "max_recovered"])

    def test_sustained_saturation_pages_once_after_five_minutes(self):
        events = simulate([10] * 10)
        self.assertEqual(events, [(0, "max_reached"), (5, "max_sustained")])

    def test_renotifies_every_thirty_minutes(self):
        events = simulate([10] * 70)
        self.assertEqual([m for m, e in events if e == "max_sustained"], [5, 35, 65])

    def test_flapping_counts_as_one_continuous_saturation(self):
        # Sube y baja del máximo cada minuto: una sola alerta, sin recuperaciones.
        events = simulate([10, 9] * 10)
        self.assertEqual([e for _, e in events], ["max_reached", "max_sustained"])

    def test_recovery_requires_ten_minutes_below_max(self):
        # Baja del máximo en el minuto 6: se recupera en el 16, no antes.
        self.assertNotIn("max_recovered", [e for _, e in simulate([10] * 6 + [8] * 10)])
        events = simulate([10] * 6 + [8] * 11)
        self.assertEqual(events[-1], (16, "max_recovered"))

    def test_headroom_warning_emitted_once(self):
        events = simulate([5, 8, 8, 9, 9, 8])
        self.assertEqual(events, [(1, "headroom_low")])


class SeverityTest(unittest.TestCase):
    def test_tier1_blocked_scale_out_is_critical(self):
        s = snap(10, demand_exceeds_max=True)
        self.assertEqual(cm.severity_for("max_sustained", s, cluster_saturated=False), "critical")

    def test_no_pressure_downgrades_one_level(self):
        s = snap(10, demand_exceeds_max=False)
        self.assertEqual(cm.severity_for("max_sustained", s, cluster_saturated=False), "high")

    def test_untagged_service_defaults_to_medium(self):
        s = snap(10, tags={})
        self.assertEqual(cm.severity_for("max_sustained", s, cluster_saturated=False), "medium")

    def test_cluster_saturation_demotes_service_alerts(self):
        s = snap(10, demand_exceeds_max=True)
        self.assertEqual(cm.severity_for("max_sustained", s, cluster_saturated=True), "medium")


class RunTest(unittest.TestCase):
    def test_alert_payload(self):
        s = snap(10, demand_exceeds_max=True, cpu_avg_5m=87.2, memory_avg_5m=54.0)
        states = {s.key: cm.ServiceState(status=cm.STATUS_AT_MAX, since=T0)}
        lines, _ = cm.run([s], states, T0 + 420, CFG, "333333333333", "us-east-1")
        alert = next(line for line in lines if line["event_type"] == "ecs.capacity.max_sustained")

        self.assertEqual(alert["severity"], "critical")
        self.assertEqual(alert["dedup_key"], "ecs-capacity:production:core/payments-processor")
        self.assertEqual(alert["capacity"]["desired"], 10)
        self.assertEqual(alert["duration_seconds"], 420)
        self.assertEqual(alert["owner_team"], "payments")
        self.assertIn("7 min", alert["message"])
        self.assertIn("bloqueó", alert["message"])

    def test_cluster_summary_is_valid_emf(self):
        lines, _ = cm.run([snap(10), snap(3, service="profile")], {}, T0, CFG)
        summary = next(ln for ln in lines if ln["event_type"] == "ecs.capacity.cluster_summary")
        metrics = summary["_aws"]["CloudWatchMetrics"][0]
        for name in (m["Name"] for m in metrics["Metrics"]):
            self.assertIn(name, summary)
        for dim in metrics["Dimensions"][0]:
            self.assertIn(dim, summary)
        self.assertEqual(summary["ServicesAtMax"], 1)

    def test_cluster_saturation_flagged_when_three_services_at_max(self):
        snaps = [snap(10, service=f"svc-{i}") for i in range(3)]
        states = {s.key: cm.ServiceState(status=cm.STATUS_AT_MAX, since=T0) for s in snaps}
        lines, _ = cm.run(snaps, states, T0 + 300, CFG)
        alerts = [line for line in lines if line["event_type"] == "ecs.capacity.max_sustained"]
        self.assertEqual(len(alerts), 3)
        self.assertTrue(all(a["cluster_saturated"] for a in alerts))

    def test_healthy_services_snapshot_every_five_minutes(self):
        s = snap(3)
        snapshots_per_minute = [
            sum(
                line["event_type"] == "ecs.capacity.snapshot"
                for line in cm.run([s], {}, T0 + m * 60, CFG)[0]
            )
            for m in range(10)
        ]
        self.assertEqual(sum(snapshots_per_minute), 2)


class AwsAdaptersTest(unittest.TestCase):
    def test_list_scalable_targets_parses_resource_id(self):
        aas = mock.Mock()
        aas.get_paginator.return_value.paginate.return_value = [
            {
                "ScalableTargets": [
                    {
                        "ResourceId": "service/core/payments-processor",
                        "ScalableDimension": "ecs:service:DesiredCount",
                        "MinCapacity": 2,
                        "MaxCapacity": 10,
                    },
                    {
                        "ResourceId": "service/core/other",
                        "ScalableDimension": "ecs:service:Other",
                        "MinCapacity": 1,
                        "MaxCapacity": 1,
                    },
                ]
            }
        ]
        self.assertEqual(cm.list_scalable_targets(aas), {("core", "payments-processor"): (2, 10)})

    def test_demand_exceeds_max_reads_not_scaled_reasons(self):
        aas = mock.Mock()
        aas.describe_scaling_activities.return_value = {
            "ScalingActivities": [
                {
                    "StartTime": datetime.fromtimestamp(T0 - 60, tz=UTC),
                    "NotScaledReasons": [{"Code": "AlreadyAtMaxCapacity", "MaxCapacity": 10}],
                }
            ]
        }
        self.assertTrue(cm.demand_exceeds_max(aas, snap(10), T0))
        aas.describe_scaling_activities.assert_called_once()
        self.assertTrue(
            aas.describe_scaling_activities.call_args.kwargs["IncludeNotScaledActivities"]
        )

    def test_old_scaling_activity_is_ignored(self):
        aas = mock.Mock()
        aas.describe_scaling_activities.return_value = {
            "ScalingActivities": [
                {
                    "StartTime": datetime.fromtimestamp(T0 - 3600, tz=UTC),
                    "NotScaledReasons": [{"Code": "AlreadyAtMaxCapacity"}],
                }
            ]
        }
        self.assertFalse(cm.demand_exceeds_max(aas, snap(10), T0))

    def test_describe_services_batches_by_ten(self):
        ecs = mock.Mock()
        ecs.describe_services.side_effect = lambda cluster, services, include: {
            "services": [
                {
                    "serviceName": s,
                    "status": "ACTIVE",
                    "desiredCount": 2,
                    "runningCount": 2,
                    "pendingCount": 0,
                    "tags": [],
                }
                for s in services
            ]
        }
        targets = {("core", f"svc-{i}"): (1, 5) for i in range(23)}
        self.assertEqual(len(cm.describe_services(ecs, targets)), 23)
        self.assertEqual(ecs.describe_services.call_count, 3)

    def test_save_states_writes_only_changes_and_deletes_gone_services(self):
        table = mock.MagicMock()
        batch = table.batch_writer.return_value.__enter__.return_value
        same = cm.ServiceState(status=cm.STATUS_OK, since=T0)
        old = {"core/a": same, "core/gone": same}
        new = {"core/a": same, "core/b": cm.ServiceState(status=cm.STATUS_AT_MAX, since=T0)}
        cm.save_states(table, old, new)
        batch.put_item.assert_called_once()
        self.assertEqual(batch.put_item.call_args.kwargs["Item"]["pk"], "core/b")
        batch.delete_item.assert_called_once_with(Key={"pk": "core/gone"})


if __name__ == "__main__":
    unittest.main()
