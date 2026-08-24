import UIKit

/// The three ways of getting in touch, gathered off the About card.
///
/// Help, Send Feedback and Report a Site Problem were three rows sitting
/// between the version number and the legal documents — the part of Settings
/// people scroll past, holding the part they would want if something went
/// wrong. One row named for what it is puts them where somebody would look for
/// them, and gives About back its shape: what this is, then how to reach us,
/// then the paperwork.
final class SupportOptionsViewController: UIViewController {

    /// Handed back to the browser, which owns opening a page or composing mail.
    var onOpen: ((SupportDestination) -> Void)?

    private struct Row {
        let title: String
        let subtitle: String
        let destination: SupportDestination
    }

    private let table = UITableView(frame: .zero, style: .insetGrouped)

    /// Only what there is somewhere to send — the same test the About card
    /// made before these moved here. A row that opens nothing is worse than a
    /// row that isn't there.
    private var rows: [Row] {
        var rows: [Row] = []
        if SupportInfo.hasWebsite {
            rows.append(Row(title: "Website",
                            subtitle: "What TitleLess is, and what it refuses to do.",
                            destination: .website))
        }
        if SupportInfo.hasSupportURL {
            rows.append(Row(title: "Help",
                            subtitle: "Answers to the questions people ask most.",
                            destination: .help))
        }
        if SupportInfo.hasContact {
            rows.append(Row(title: "Send Feedback",
                            subtitle: "Tell us what is missing, wrong or in the way.",
                            destination: .feedback))
            rows.append(Row(title: "Report a Site Problem",
                            subtitle: "A page that loads wrong, or an ad that got through.",
                            destination: .siteProblem))
        }
        return rows
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Support"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

// MARK: - Table

extension SupportOptionsViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let row = rows[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.title
        content.secondaryText = row.subtitle
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onOpen?(rows[indexPath.row].destination)
    }
}
