import Foundation

// swiftlint:disable line_length

/// APP-09v-c 资金零改动基线（入场底版 0137679 生成；brief §3、§5，prompt「资金写页硬约束」）。逻辑文件逐字节、回调块按空白折叠后的 SHA-256。
/// 不是可以随手更新的快照：这里变了就是动了资金逻辑或受保护测试，须走「需要编排裁定」。
enum WithdrawVisualBaseline {
    /// WalletCore 全部源文件（除文案表 WalletDraftTable*.swift、WalletTexts.swift）。
    static let logicFiles: [String: String] = [
        "Packages/Core/Sources/WalletCore/FieldErrorCue.swift": "d1265d63d9feb678eb36aad43ab771821dc5ad2839d116fb4e65e4d9a42b1610",
        "Packages/Core/Sources/WalletCore/LaborAgreementController.swift": "ac2d90de5660218fa134f98fc3c71aa6d0c3a815c02e0776765cd069bc84b40a",
        "Packages/Core/Sources/WalletCore/PayoutAccountController+Form.swift": "8722cbb2fa6574cb28749f969175a0038430b159862c2ad7ae9a1ecb599ac6fd",
        "Packages/Core/Sources/WalletCore/PayoutAccountController.swift": "7b2ac624ab6968bd3e1869a79a48e946b3b86a77974689ef42da074a2d0d7051",
        "Packages/Core/Sources/WalletCore/PayoutLogic.swift": "9f9bfaf6e4602d80147af6e96389ae2b2d7c127ef51bea7fa42ab3867b7aea8d",
        "Packages/Core/Sources/WalletCore/RealNameRemote.swift": "52b9b85077b4a58d688c26b532f49e23fb758b85b785ac5fdec85a3fc192e824",
        "Packages/Core/Sources/WalletCore/RealNameController+Idempotency.swift": "591e730e4db30877a323b2724334adbb58d152ce035b54a26857c08b04fdaba6",
        "Packages/Core/Sources/WalletCore/RealNameController.swift": "f456ac9322afd29f863df0eaf21f825342980d8343508cfc986a543b4a02a96e",
        "Packages/Core/Sources/WalletCore/SensitiveFlow+Apply.swift": "29c6272c1de1f6b5ae734f64492f1a7e972770bc9224d4af5ea7329d2c9ab20c",
        "Packages/Core/Sources/WalletCore/SensitiveFlow+Pending.swift": "5a7ea75c4bac3a8cd50563601e2cead2568e9016d4cc289e1d452600c2a9b361",
        "Packages/Core/Sources/WalletCore/SensitiveFlow.swift": "212eca736f4f112051656ee0565120c0e6b080dc0fe03d925761552d6f0b5ba8",
        "Packages/Core/Sources/WalletCore/SensitiveOutcome.swift": "037e1a1ab34ede89fc158fdeb11efc83e1fab6ebf1092a1835f0b6fd641903b2",
        "Packages/Core/Sources/WalletCore/StepUpController+Send.swift": "2540e710dd9729f0ed7c7cdf33b059725bbdf7f9ddf5a5dd392ac7e2918c33e8",
        "Packages/Core/Sources/WalletCore/StepUpController.swift": "8db07a9e40ad216aa1148d6735c31b37c4456a60d242d940aabe560b273e5a61",
        "Packages/Core/Sources/WalletCore/WalletController.swift": "ce4bd3fdeffe51d3fa01a3741036b5fcc257e39faf66a8b70b6d7f740e84601b",
        "Packages/Core/Sources/WalletCore/WalletDeps.swift": "bd7ab0f44b4cf65878e9012de23060a93cbab42aba931c480b449232c3d7306a",
        "Packages/Core/Sources/WalletCore/WalletErrors.swift": "22c49b381392773e5f96323933510783815b3dc155bdc718e091a1ceec208904",
        "Packages/Core/Sources/WalletCore/WalletModels.swift": "4c8f7ce8a7beb4c8ffb5ca5d4f7fa8fdd8d70c34318cf17cb9cf3564c26b34cb",
        "Packages/Core/Sources/WalletCore/WalletRequests.swift": "4355d3c00a9eb0d922bfa5e93e02b009c9cc58005f8167ff8810c448b01e03d5",
        "Packages/Core/Sources/WalletCore/WalletSettlement.swift": "5422d272e253a7e972012f4a57f67d8287412ec9d17c448a87b11e1fac79b545",
        "Packages/Core/Sources/WalletCore/WalletStaleCache.swift": "b1f94093612053f92b0d93b505de6623787049c4b730738fc7c7140df713d65e",
        "Packages/Core/Sources/WalletCore/WalletSummaryView.swift": "501b402e17e75c618e83bb0c9322aeb15857949cf4e2e1889a2005a43e823e0a",
        "Packages/Core/Sources/WalletCore/WalletVectorWiring.swift": "c7651e991848e90621ca8d43cd3de513b5cab48353fc8985777c00dc9ceb2778",
        "Packages/Core/Sources/WalletCore/WithdrawController+Actions.swift": "37d9237131034ef9ccc3b2a85fac9bf0a9798b575e11c67aa649d29ba239bc74",
        "Packages/Core/Sources/WalletCore/WithdrawController+Rules.swift": "4f0dc0ff7669fd9c956ec02f0317550efb89f40678e82640735e9436d0adc6c1",
        "Packages/Core/Sources/WalletCore/WithdrawController.swift": "792a58c5089585563e4bc927e3b634d311dd8d6ef203b73e7c2997964c23149f",
        "Packages/Core/Sources/WalletCore/WithdrawLogic.swift": "6f2d605b0c40a9b4c6f648afbe9c8cd03280ed3125f1ec1e1ce4b525325ac5e4",
        "Packages/Core/Sources/WalletCore/WithdrawRecordSections.swift": "570205c5195f28ed86deed1a77c7541d70033d4786bb13a9d7fee9db942e3494",
        "Packages/Core/Sources/WalletCore/WithdrawRecordsController+Items.swift": "94bbc78d8fe73f0bbe552551fa9539134477678e048437b545ecb10edd31a202",
        "Packages/Core/Sources/WalletCore/WithdrawRecordsController.swift": "844674f72e23d8b10b29fa446bfe89f076e1cee6ddabcabbac272da0a30680df",
        "Packages/Core/Sources/WalletCore/WithdrawalText.swift": "5ff34329d980f5d414f2ada37cacee92822f09b23339c99218b9007fa2bf3962",
    ]

    /// 受保护的旧测试（G-W26 精神：资金回归零改动）。
    static let protectedTests: [String: String] = [
        "AppTests/FollowupIos0712EpochTests.swift": "2ca67b97b05887aeed277f75a0ca5b9a692ff7f3f5c6ffb25d8909703e319da1",
        "AppTests/FollowupIos0712FixR1BackgroundSaveTests.swift": "39c20410125df059ce736cd33fd42190d104cf6f778fe4e5bcb7cdf546463ae8",
        "AppTests/FollowupIos0712FixR1ClipboardTests.swift": "9dd8b583b46cd8221798906006d9466ff8b488087b0bf5089e8d54bda366a7b6",
        "AppTests/FollowupIos0712FixR1ColdStartTests.swift": "2537373625792a462d69b4928070184166ad47a0304782f2f4ce5f0a3bce5caa",
        "AppTests/FollowupIos0712FixR1EpochTests.swift": "91e73af61705a2769058f6882acd44bc55677e1238b73c1f07b83e120cdaa885",
        "AppTests/FollowupIos0712FixR1RefreshTests.swift": "71b98b6894660e4a00a829ac504a4f9d7ccea836587b8757ad6c6b8ed866b367",
        "AppTests/FollowupIos0712FixR3Tests.swift": "3c010f0bb52c1a2660d4ed897ada731b83163c22d32d15cc74058d9323795882",
        "AppTests/FollowupIos0712FixR3bTests.swift": "53eab9f11a38b7516843e8392fe80bc934601e911a8560bf2b50019259e2716b",
        "AppTests/FollowupIos0712FixR3cTests.swift": "9b68c2a9b92bd394ea4c7c37fc0fa6284e35ed84c6ae933cf57095d79f512e12",
        "AppTests/FollowupIos0712FixR3dTests.swift": "d24dc316b2fd01030198c0563799c9157b2685edc7ae8393b607c47b14588c8c",
        "AppTests/FollowupIos0712FixRework2Tests.swift": "e07c53a7646be875b50de825ed9878ad1ce41dee55e8be0d2a75db658e1396ff",
        "AppTests/FollowupIos0712FixRework3FaultTests.swift": "e231fb0ab62a3046aaf5c4054cc34d486b323342d576b590d023adafd7e5ee99",
        "AppTests/FollowupIos0712FixRework3Tests.swift": "b931397ddeb41cac38283461293bfbf8f1a47fde78611b92137220464ad40e45",
        "AppTests/FollowupIos0712FixReworkMoneyTests.swift": "4eb993bfd958b36b9965b949315574c1d310fe61f92a3367110c2b8749296a59",
        "AppTests/FollowupIos0712FixReworkTests.swift": "992eb2b8bcc60c236a4aad9fa81c8098da1f2979594c27391c22c5dff2c99617",
        "AppTests/FollowupIos0712PushTests.swift": "95f90b75171bde5d0786addfaee8962597b0e8f40ca0efb6942ce2b54d971015",
        "AppTests/FollowupIos0712ReworkOrderTests.swift": "b9d636d2891317fe12c692f5ca17cda8bd127083dfd6dc73aaf20916f0671098",
        "AppTests/FollowupIos0712ReworkWalletMoreTests.swift": "2096c3ae462616e4b82a2083594a50a598c056eb42bc4f03fd7e1458fcc64b93",
        "AppTests/FollowupIos0712ReworkWalletTests.swift": "882cfb2de055b96adc76ca37891840875973dffd4328e374896be766c16aa8e2",
        "AppTests/FollowupIos0712UpdateTests.swift": "f22ada74ade235b80be871ce44f1cf3770542421f9af4d31a78249e4bcbf2c63",
        "AppTests/FollowupIos0713FinalPendingTests.swift": "fb045a5919e835d518085e34b82b56f2e9a4b62baa9ea51b2b9acc48e210b53c",
        "AppTests/FollowupIos0713FinalSignalTests.swift": "8ef27a349f9c8538f6cc8897772b40b6b4626c0b62885b40bff908b4e28a6ab8",
        "AppTests/FollowupIos0713FinalTests.swift": "590df6989429a01756b35bafb485dbbf9b36330c7fee5c2085bfc6eaffdc9bcf",
        "AppTests/FollowupIos0713IdentityWriteTests.swift": "c0a62acbbac33472ec0b8bef0b2563739b0c22a8e7d7838ae8e993ccdd6051f1",
        "AppTests/FollowupIos0713Me10006Tests.swift": "cdf1221199d232ae27baa366d0c51e95cc9a6776bf30d679b66b31501fbd7d1b",
        "AppTests/FollowupIos0713MeSectionTests.swift": "eafdaf03a75d2ebf7275f3ce78ed149f5b671964df00826eb6827ad904bbba71",
        "AppTests/FollowupIos0713MeTests.swift": "920d0d1c9c83ec7b28cc7544af39a7ac27058a95220623f50c575dbbe0b845b7",
        "AppTests/FollowupIos0713PendingTrackTests.swift": "814d297b7360b827ad79610e234fa5259d3916e72a8c9941b476b925e6df9374",
        "AppTests/FollowupIos0713StepUpTests.swift": "2c0bc38cc9eadf13a3a3a9a39a7ea902cf375500988172f057bf79e7f13e49e5",
        "AppTests/FollowupIos0713StepUpVerifyTests.swift": "551b6517a7066cadf76dd004dc93b178e674a196b7b5a8c9490b78c704ed940d",
        "AppTests/FollowupIos0713Support.swift": "2ce15714ac44b5e50d090a254e187143695696c58917f5a8c373b15e037d8903",
        "AppTests/PayoutAccountTests.swift": "8fd826c53a25e1080845964d84600a01dcd8684507d5d9fef1445ef8df482ab8",
        "AppTests/WalletLessonsTests.swift": "492f78de7cf5b9cad99af74bb4672b0fd4ee7a9ffd2256284b8cb8323b1fd700",
        "AppTests/WalletNavigationTests.swift": "090661311ac2063558b35e9ed521a802e22fa611e79621cac44576270977e7cd",
        "AppTests/WalletPageTests.swift": "789562044d5e48c26df78b430797a49724bb70fd88d7e33012fd8f14cf0ce00b",
        "AppTests/WalletReviewR1PageTests.swift": "2b07511ebcd00548a52daea368f42238fc883a2e54790b9fc6c587d9a7c5ad32",
        "AppTests/WalletReviewR1SettleTests.swift": "412b904aa99ec4e45e305747a57cee163814cd846c077df98181831309c07716",
        "AppTests/WalletReviewR1Tests.swift": "a158a61f0b86f7274c6e92dfa59a8bf10815510c1365aca6840917d13be755f1",
        "AppTests/WalletReviewR2Tests.swift": "836a3f43925c749fe42b886b244301e0127f1f70ca7ebebd687e65f0bb6a8535",
        "AppTests/WalletReviewR3Tests.swift": "dae06b3c3d048e3d1f85bff37ecaa9b58ab222984502acef4fd5d722fb802d10",
        "AppTests/WalletSessionTests.swift": "c3fa1eb03c46664fc5ab6eb5c9093eb9285aa9a80a5e73a64c8827f360e7c406",
        "AppTests/WalletWithdrawGuardTests.swift": "1bc7ab8b9c19532dd63ef3e8128f94ba98832584516dc6e528759ac6fc833649",
        "AppTests/WithdrawEstimateTests.swift": "5151d23604c34b822575cd6e6df5697354a5cb92f37559c2797e54dd580d5dbe",
        "AppTests/WithdrawGuideTests.swift": "ed9b727fc64eca8d4e04bcc519ebac1d30f5204adace951e6beeac6bcd9553ef",
        "AppTests/WithdrawPendingTests.swift": "3457ee9cf84eca1b56ca391e49f8d83dccc44af748ccee77df9ca7887cb5d357",
        "AppTests/WithdrawSubmitTests.swift": "47b28affea4bc438ad560aa54a1309320b0f461a68828d5e0c552b2f39160068",
    ]

    /// `WithdrawActions`（结构 + make）折叠空白后的 SHA-256。
    static let withdrawActions = "127bb90b1b51b100b6ce5245dfa37296cda357be89e4f087529dca0fbbd6689f"
    /// `FlowActions`（结构 + make）折叠空白后的 SHA-256。
    static let flowActions = "cfd0ad230ece2fce734c91c2dc9873eeec6fdb7245610fdae4b7bc20d4a598c4"
}

// swiftlint:enable line_length
