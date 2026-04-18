import { Module } from '@nestjs/common';
import { RestaurantsService } from './restaurants.service';
import { RestaurantsController } from './restaurants.controller';
import { DatabaseModule } from '../../config/database/database.module';
import { MenusModule } from '../menus/menus.module';
import { CategoriesModule } from '../categories/categories.module';
import { ProductsModule } from '../products/products.module';
import { PlansModule } from '../plans/plans.module';
import { TemplatesModule } from '../templates/templates.module';
import { BranchesModule } from '../branches/branches.module';
import { BannersModule } from '../banners/banners.module';

@Module({
  imports: [
    DatabaseModule,
    MenusModule,
    CategoriesModule,
    ProductsModule,
    PlansModule,
    TemplatesModule,
    BranchesModule,
    BannersModule,
  ],
  controllers: [RestaurantsController],
  providers: [RestaurantsService],
})
export class RestaurantsModule {}
